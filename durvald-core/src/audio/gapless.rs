//! Switch prebuffered streams on the audio thread, rather than a UI/poll timer.
//! Ring buffers also return old streams to the control thread for destruction.
use kira::{
    Frame, Tween,
    info::Info,
    sound::{
        FromFileError, PlaybackState, Sound, SoundData,
        streaming::{StreamingSoundData, StreamingSoundHandle},
    },
};
use rtrb::{Consumer, Producer, RingBuffer};
use std::{
    convert::Infallible,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

pub(super) const ACTIVATING: u64 = 1 << 63;

pub(super) struct Voice {
    pub sound: Box<dyn Sound>,
    pub duration: f64,
    pub token: u64,
    handle: StreamingSoundHandle<FromFileError>,
    control: Arc<Control>,
}

struct Control {
    state: AtomicU64,
    position: AtomicU64,
    volume: AtomicU64,
    seek: AtomicU64,
    action: AtomicU64,
    stop_duration: AtomicU64,
    manually_stopped: AtomicBool,
}

pub(super) struct StreamHandle {
    control: Arc<Control>,
}

impl StreamHandle {
    pub fn state(&self) -> PlaybackState {
        match self.control.state.load(Ordering::Acquire) {
            0 => PlaybackState::Playing,
            1 => PlaybackState::Pausing,
            2 => PlaybackState::Paused,
            3 => PlaybackState::WaitingToResume,
            4 => PlaybackState::Resuming,
            5 => PlaybackState::Stopping,
            _ => PlaybackState::Stopped,
        }
    }
    pub fn position(&self) -> f64 {
        f64::from_bits(self.control.position.load(Ordering::Acquire))
    }
    pub fn set_volume(&mut self, db: f32, _: Tween) {
        self.control
            .volume
            .store((db as f64).to_bits(), Ordering::Release);
    }
    pub fn pause(&mut self, _: Tween) {
        self.control.action.store(1, Ordering::Release);
    }
    pub fn resume(&mut self, _: Tween) {
        self.control.action.store(2, Ordering::Release);
    }
    pub fn stop(&mut self, tween: Tween) {
        self.control.manually_stopped.store(true, Ordering::Release);
        self.control
            .stop_duration
            .store(tween.duration.as_secs_f64().to_bits(), Ordering::Release);
        self.control.action.store(3, Ordering::Release);
    }
    pub fn seek_to(&mut self, seconds: f64) {
        self.control
            .seek
            .store(seconds.to_bits(), Ordering::Release);
    }
}

impl Voice {
    pub fn prepare(
        data: StreamingSoundData<FromFileError>,
        token: u64,
    ) -> Result<(Self, StreamHandle), FromFileError> {
        let duration = data.duration().as_secs_f64();
        let (sound, handle) = data.into_sound()?;
        let control = Arc::new(Control {
            state: AtomicU64::new(0),
            position: AtomicU64::new(0),
            volume: AtomicU64::new(f64::NAN.to_bits()),
            seek: AtomicU64::new(f64::NAN.to_bits()),
            action: AtomicU64::new(0),
            stop_duration: AtomicU64::new(0),
            manually_stopped: AtomicBool::new(false),
        });
        Ok((
            Self {
                sound,
                duration,
                token,
                handle,
                control: control.clone(),
            },
            StreamHandle { control },
        ))
    }
    fn update(&mut self) {
        let immediate = Tween {
            duration: std::time::Duration::ZERO,
            ..Default::default()
        };
        let volume = f64::from_bits(
            self.control
                .volume
                .swap(f64::NAN.to_bits(), Ordering::AcqRel),
        );
        if volume.is_finite() {
            self.handle.set_volume(volume as f32, Tween::default());
        }
        let seek = f64::from_bits(self.control.seek.swap(f64::NAN.to_bits(), Ordering::AcqRel));
        if seek.is_finite() {
            self.handle.seek_to(seek);
        }
        match self.control.action.swap(0, Ordering::AcqRel) {
            1 => self.handle.pause(immediate),
            2 => self.handle.resume(immediate),
            3 => self.handle.stop(Tween {
                duration: std::time::Duration::from_secs_f64(f64::from_bits(
                    self.control.stop_duration.load(Ordering::Acquire),
                )),
                ..Default::default()
            }),
            _ => {}
        }
        self.sound.on_start_processing();
        self.publish();
    }
    fn publish(&self) {
        self.control
            .state
            .store(self.handle.state() as u64, Ordering::Release);
        self.control
            .position
            .store(self.handle.position().to_bits(), Ordering::Release);
    }
    fn retire(&mut self) {
        self.handle.stop(Tween {
            duration: std::time::Duration::ZERO,
            ..Default::default()
        });
        self.sound.on_start_processing();
        self.publish();
    }
}

impl Drop for Voice {
    fn drop(&mut self) {
        // Also stop a decoder cancelled before it reaches the renderer.
        self.retire();
    }
}

pub(super) struct Shared {
    pub active: AtomicU64,
    pub pending: AtomicU64,
}

pub(super) struct Transport {
    pub shared: Arc<Shared>,
    pub incoming: Producer<Voice>,
    retired: Consumer<Voice>,
}

impl Transport {
    pub fn collect(&mut self) {
        while let Ok(voice) = self.retired.pop() {
            drop(voice);
        }
    }
}

pub(super) struct GaplessData {
    sound: GaplessSound,
    transport: Transport,
}

impl GaplessData {
    pub fn new(first: Voice) -> Self {
        let (incoming, receiver) = RingBuffer::new(4);
        let (retired, collector) = RingBuffer::new(8);
        let shared = Arc::new(Shared {
            active: AtomicU64::new(first.token),
            pending: AtomicU64::new(0),
        });
        Self {
            sound: GaplessSound {
                current: Some(first),
                next: None,
                elapsed: 0.0,
                shared: shared.clone(),
                incoming: receiver,
                retired,
            },
            transport: Transport {
                shared,
                incoming,
                retired: collector,
            },
        }
    }
}

impl SoundData for GaplessData {
    type Error = Infallible;
    type Handle = Transport;
    fn into_sound(self) -> Result<(Box<dyn Sound>, Transport), Infallible> {
        Ok((Box::new(self.sound), self.transport))
    }
}

struct GaplessSound {
    current: Option<Voice>,
    next: Option<Voice>,
    elapsed: f64,
    shared: Arc<Shared>,
    incoming: Consumer<Voice>,
    retired: Producer<Voice>,
}

impl Sound for GaplessSound {
    fn on_start_processing(&mut self) {
        // Never free a decoder or its buffers in the real-time callback.
        while self.retired.slots() > 1 {
            let Ok(voice) = self.incoming.pop() else {
                break;
            };
            if let Some(mut previous) = self.next.replace(voice) {
                previous.retire();
                let _ = self.retired.push(previous);
            }
        }
        if self
            .next
            .as_ref()
            .is_some_and(|voice| voice.token != self.shared.pending.load(Ordering::Acquire))
            && !self.retired.is_full()
        {
            let mut voice = self.next.take().unwrap();
            voice.retire();
            let _ = self.retired.push(voice);
        }
        if let Some(current) = &mut self.current {
            current.update();
            // Follow the renderer's actual progress, including decoder stalls
            // and seeks, rather than wall-clock time.
            self.elapsed = current.handle.position();
        }
        if let Some(next) = &mut self.next {
            next.update();
        }
    }

    fn process(&mut self, out: &mut [Frame], dt: f64, info: &Info) {
        let mut offset = 0;
        while offset < out.len() {
            let advancing = self
                .current
                .as_ref()
                .is_some_and(|voice| voice.handle.state().is_advancing());
            let naturally_finished = self.current.as_ref().is_some_and(|voice| {
                voice.sound.finished() && !voice.control.manually_stopped.load(Ordering::Acquire)
            });
            let at_boundary = self.current.as_ref().is_some_and(|voice| {
                self.elapsed + dt * 0.5 >= voice.duration || naturally_finished
            });
            if (advancing || naturally_finished)
                && at_boundary
                && !self.retired.is_full()
                && self.next.as_ref().is_some_and(|voice| {
                    self.shared
                        .pending
                        .compare_exchange(
                            voice.token,
                            voice.token | ACTIVATING,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                })
            {
                let next = self.next.take().unwrap();
                let token = next.token;
                if let Some(mut previous) = self.current.replace(next) {
                    previous.retire();
                    let _ = self.retired.push(previous);
                }
                self.elapsed = 0.0;
                self.shared.active.store(token, Ordering::Release);
                continue;
            }
            let remaining = out.len() - offset;
            let count = if advancing && self.next.is_some() && !at_boundary {
                self.current.as_ref().map_or(remaining, |voice| {
                    (((voice.duration - self.elapsed) / dt).round() as usize)
                        .max(1)
                        .min(remaining)
                })
            } else {
                remaining
            };
            let chunk = &mut out[offset..offset + count];
            if let Some(current) = &mut self.current {
                current.sound.process(chunk, dt, info);
            } else {
                chunk.fill(Frame::ZERO);
            }
            if advancing {
                self.elapsed += dt * count as f64;
            }
            offset += count;
        }
        if let Some(current) = &self.current {
            current.publish();
        }
    }

    fn finished(&self) -> bool {
        self.current
            .as_ref()
            .is_none_or(|voice| voice.sound.finished())
            && self.next.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kira::info::MockInfoBuilder;
    use std::{io::Cursor, time::Duration};

    fn tone(frames: usize, sample: i16) -> StreamingSoundData<FromFileError> {
        tone_at_rate(frames, sample, 8_000)
    }

    fn tone_at_rate(
        frames: usize,
        sample: i16,
        sample_rate: u32,
    ) -> StreamingSoundData<FromFileError> {
        let bytes = (frames * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&bytes.to_le_bytes());
        for _ in 0..frames {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        StreamingSoundData::from_cursor(Cursor::new(wav)).unwrap()
    }

    #[test]
    fn rendered_samples_switch_at_the_exact_boundary_without_silence_or_overlap() {
        let (first, _) = Voice::prepare(tone(257, 8_192), 1).unwrap();
        let (second, _) = Voice::prepare(tone(401, -8_192), 2).unwrap();
        let (mut sound, mut transport) = GaplessData::new(first).into_sound().unwrap();
        transport.shared.pending.store(2, Ordering::Release);
        transport
            .incoming
            .push(second)
            .unwrap_or_else(|_| panic!("queue successor"));
        // Only the decoder runs during this wait, not a queue/UI timer.
        std::thread::sleep(Duration::from_millis(20));
        let info = MockInfoBuilder::new().build();
        let mut rendered = Vec::new();
        for count in [37, 128, 128, 128] {
            sound.on_start_processing();
            let mut frames = vec![Frame::ZERO; count];
            sound.process(&mut frames, 1.0 / 8_000.0, &info);
            rendered.extend(frames);
        }
        for (index, frame) in rendered.iter().enumerate() {
            let expected = if index < 257 { 0.25 } else { -0.25 };
            assert!(
                (frame.left - expected).abs() < 0.0001,
                "frame {index}: {frame:?}"
            );
        }
        assert_eq!(transport.shared.active.load(Ordering::Acquire), 2);
        transport.collect();
    }

    #[test]
    fn resampled_streams_with_different_rates_do_not_insert_silent_frames() {
        let (first, _) = Voice::prepare(tone_at_rate(257, 8_192, 8_000), 1).unwrap();
        let (second, _) = Voice::prepare(tone_at_rate(401, -8_192, 12_000), 2).unwrap();
        let (mut sound, mut transport) = GaplessData::new(first).into_sound().unwrap();
        transport.shared.pending.store(2, Ordering::Release);
        transport
            .incoming
            .push(second)
            .unwrap_or_else(|_| panic!("queue successor"));
        std::thread::sleep(Duration::from_millis(20));
        let info = MockInfoBuilder::new().build();
        let mut rendered = Vec::new();
        for count in [211, 777, 788, 224] {
            sound.on_start_processing();
            let mut frames = vec![Frame::ZERO; count];
            sound.process(&mut frames, 1.0 / 48_000.0, &info);
            rendered.extend(frames);
        }
        // 257 samples at 8 kHz occupy exactly 1542 frames at 48 kHz.
        for (index, frame) in rendered.iter().enumerate() {
            assert!(
                if index < 1542 {
                    frame.left > 0.0
                } else {
                    frame.left < 0.0
                },
                "inserted silence or incorrect boundary at {index}: {frame:?}"
            );
        }
        assert_eq!(transport.shared.active.load(Ordering::Acquire), 2);
        transport.collect();
    }

    #[test]
    fn resampling_matches_an_unbroken_recording_at_the_track_boundary() {
        let (first, _) = Voice::prepare(tone_at_rate(441, 8_192, 44_100), 1).unwrap();
        let (second, _) = Voice::prepare(tone_at_rate(441, 8_192, 44_100), 2).unwrap();
        let (mut split, mut transport) = GaplessData::new(first).into_sound().unwrap();
        let (mut continuous, _) = tone_at_rate(882, 8_192, 44_100).into_sound().unwrap();
        transport.shared.pending.store(2, Ordering::Release);
        transport
            .incoming
            .push(second)
            .unwrap_or_else(|_| panic!("queue successor"));
        std::thread::sleep(Duration::from_millis(20));
        let info = MockInfoBuilder::new().build();
        let mut split_output = Vec::new();
        let mut continuous_output = Vec::new();
        for _ in 0..8 {
            split.on_start_processing();
            continuous.on_start_processing();
            let mut split_frames = [Frame::ZERO; 64];
            let mut continuous_frames = [Frame::ZERO; 64];
            split.process(&mut split_frames, 1.0 / 48_000.0, &info);
            continuous.process(&mut continuous_frames, 1.0 / 48_000.0, &info);
            split_output.extend(split_frames);
            continuous_output.extend(continuous_frames);
        }
        for index in 474..486 {
            assert!(
                (split_output[index].left - continuous_output[index].left).abs() < 0.0001,
                "resampling discontinuity at {index}: split={}, continuous={}",
                split_output[index].left,
                continuous_output[index].left
            );
        }
        transport.collect();
    }

    #[test]
    fn cancelling_a_prebuffered_successor_keeps_it_out_of_the_output() {
        let (first, _) = Voice::prepare(tone(257, 8_192), 1).unwrap();
        let (second, _) = Voice::prepare(tone(401, -8_192), 2).unwrap();
        let (mut sound, mut transport) = GaplessData::new(first).into_sound().unwrap();
        transport.shared.pending.store(2, Ordering::Release);
        transport
            .incoming
            .push(second)
            .unwrap_or_else(|_| panic!("queue successor"));
        std::thread::sleep(Duration::from_millis(20));
        transport.shared.pending.store(0, Ordering::Release);
        let info = MockInfoBuilder::new().build();
        sound.on_start_processing();
        let mut frames = vec![Frame::ZERO; 400];
        sound.process(&mut frames, 1.0 / 8_000.0, &info);
        assert!(frames.iter().all(|frame| frame.left >= 0.0));
        assert_eq!(transport.shared.active.load(Ordering::Acquire), 1);
        transport.collect();
    }

    #[test]
    fn pause_does_not_advance_the_boundary_and_resume_remains_gapless() {
        let (first, mut handle) = Voice::prepare(tone(257, 8_192), 1).unwrap();
        let (second, _) = Voice::prepare(tone(401, -8_192), 2).unwrap();
        let (mut sound, mut transport) = GaplessData::new(first).into_sound().unwrap();
        transport.shared.pending.store(2, Ordering::Release);
        transport
            .incoming
            .push(second)
            .unwrap_or_else(|_| panic!("queue successor"));
        std::thread::sleep(Duration::from_millis(20));
        let info = MockInfoBuilder::new().build();
        sound.on_start_processing();
        sound.process(&mut [Frame::ZERO; 37], 1.0 / 8_000.0, &info);
        handle.pause(Tween::default());
        sound.on_start_processing();
        let mut paused = [Frame::ZERO; 400];
        sound.process(&mut paused, 1.0 / 8_000.0, &info);
        assert!(paused.iter().all(|frame| *frame == Frame::ZERO));
        assert_eq!(transport.shared.active.load(Ordering::Acquire), 1);
        handle.resume(Tween::default());
        sound.on_start_processing();
        let mut resumed = [Frame::ZERO; 256];
        sound.process(&mut resumed, 1.0 / 8_000.0, &info);
        for (index, frame) in resumed.iter().enumerate() {
            if index < 220 {
                // Kira smooths the resume gain; this must still be the first
                // track, never a successor advanced during the pause.
                assert!(frame.left > 0.0, "frame {index}: {frame:?}");
            } else {
                assert!(
                    (frame.left + 0.25).abs() < 0.0001,
                    "frame {index}: {frame:?}"
                );
            }
        }
        assert_eq!(transport.shared.active.load(Ordering::Acquire), 2);
        transport.collect();
    }
}
