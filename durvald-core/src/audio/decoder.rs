//! Symphonia's gapless demuxing removes encoder delay/padding when supplied by
//! the file (not silence that is part of the actual recording).
use kira::{
    Frame,
    sound::{FromFileError, streaming::Decoder},
};
use std::{fs::File, path::Path};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{Decoder as CodecDecoder, DecoderOptions},
    formats::{FormatOptions, FormatReader, SeekMode, SeekTo},
    io::MediaSourceStream,
    probe::Hint,
};

pub(super) struct GaplessDecoder {
    reader: Box<dyn FormatReader>,
    codec: Box<dyn CodecDecoder>,
    track_id: u32,
    sample_rate: u32,
    frames: usize,
}

impl GaplessDecoder {
    pub fn open(path: &str) -> Result<Self, FromFileError> {
        let source = MediaSourceStream::new(Box::new(File::open(path)?), Default::default());
        let mut hint = Hint::new();
        if let Some(extension) = Path::new(path).extension().and_then(|value| value.to_str()) {
            hint.with_extension(extension);
        }
        let reader = symphonia::default::get_probe()
            .format(
                &hint,
                source,
                &FormatOptions {
                    enable_gapless: true,
                    ..Default::default()
                },
                &Default::default(),
            )?
            .format;
        let track = reader
            .default_track()
            .ok_or(FromFileError::NoDefaultTrack)?;
        let sample_rate = track
            .codec_params
            .sample_rate
            .ok_or(FromFileError::UnknownSampleRate)?;
        let frames = track
            .codec_params
            .n_frames
            .ok_or(FromFileError::UnknownDuration)? as usize;
        let track_id = track.id;
        let codec = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())?;
        Ok(Self {
            reader,
            codec,
            track_id,
            sample_rate,
            frames,
        })
    }
}

impl Decoder for GaplessDecoder {
    type Error = FromFileError;
    fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    fn num_frames(&self) -> usize {
        self.frames
    }
    fn decode(&mut self) -> Result<Vec<Frame>, FromFileError> {
        let packet = loop {
            let packet = self.reader.next_packet()?;
            if packet.track_id() == self.track_id {
                break packet;
            }
        };
        let audio = self.codec.decode(&packet)?;
        let channels = audio.spec().channels.count();
        if !(1..=2).contains(&channels) {
            return Err(FromFileError::UnsupportedChannelConfiguration);
        }
        let mut buffer = SampleBuffer::<f32>::new(audio.capacity() as u64, *audio.spec());
        buffer.copy_interleaved_ref(audio);
        Ok(buffer
            .samples()
            .chunks_exact(channels)
            .map(|samples| Frame::new(samples[0], *samples.get(1).unwrap_or(&samples[0])))
            .collect())
    }
    fn seek(&mut self, index: usize) -> Result<usize, FromFileError> {
        let seek = self.reader.seek(
            SeekMode::Accurate,
            SeekTo::TimeStamp {
                ts: index as u64,
                track_id: self.track_id,
            },
        )?;
        self.codec.reset();
        Ok(seek.actual_ts as usize)
    }
}
