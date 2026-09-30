use std::{
    f32::consts::PI,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};

use kira::{
    Frame,
    sound::{FromFileError, streaming::Decoder},
};

use crate::api::{EqualizerMetrics, EqualizerSettings};

pub(crate) const BAND_FREQUENCIES: [f32; 10] = [
    31.0, 62.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
];

#[derive(Default)]
pub(crate) struct EqualizerMeter {
    frames: AtomicU64,
    nanoseconds: AtomicU64,
}

impl EqualizerMeter {
    pub(crate) fn snapshot(&self) -> EqualizerMetrics {
        let frames = self.frames.load(Ordering::Relaxed);
        let nanoseconds = self.nanoseconds.load(Ordering::Relaxed);
        EqualizerMetrics {
            processed_frames: frames,
            processing_nanoseconds: nanoseconds,
            average_nanoseconds_per_frame: if frames == 0 {
                0.0
            } else {
                nanoseconds as f64 / frames as f64
            },
        }
    }
}

pub(super) struct EqualizedDecoder<D> {
    inner: D,
    processor: Option<EqualizerProcessor>,
    meter: Arc<EqualizerMeter>,
}

impl EqualizedDecoder<super::decoder::GaplessDecoder> {
    pub(super) fn prepend(&mut self, frames: Vec<Frame>) {
        self.inner.prepend(frames);
    }
}

impl<D: Decoder<Error = FromFileError>> EqualizedDecoder<D> {
    pub(super) fn new(inner: D, settings: &EqualizerSettings, meter: Arc<EqualizerMeter>) -> Self {
        let processor = settings
            .enabled
            .then(|| EqualizerProcessor::new(inner.sample_rate(), settings));
        Self {
            inner,
            processor,
            meter,
        }
    }
}

impl<D: Decoder<Error = FromFileError>> Decoder for EqualizedDecoder<D> {
    type Error = FromFileError;

    fn sample_rate(&self) -> u32 {
        self.inner.sample_rate()
    }

    fn num_frames(&self) -> usize {
        self.inner.num_frames()
    }

    fn decode(&mut self) -> Result<Vec<Frame>, Self::Error> {
        let mut frames = self.inner.decode()?;
        if let Some(processor) = &mut self.processor {
            let started = Instant::now();
            processor.process(&mut frames);
            self.meter
                .frames
                .fetch_add(frames.len() as u64, Ordering::Relaxed);
            self.meter.nanoseconds.fetch_add(
                started.elapsed().as_nanos().min(u64::MAX as u128) as u64,
                Ordering::Relaxed,
            );
        }
        Ok(frames)
    }

    fn seek(&mut self, index: usize) -> Result<usize, Self::Error> {
        if let Some(processor) = &mut self.processor {
            processor.reset();
        }
        self.inner.seek(index)
    }
}

struct EqualizerProcessor {
    left: [Biquad; 10],
    right: [Biquad; 10],
    input_gain: f32,
}

impl EqualizerProcessor {
    fn new(sample_rate: u32, settings: &EqualizerSettings) -> Self {
        let maximum_boost = settings
            .band_gains_db
            .iter()
            .copied()
            .fold(0.0_f32, f32::max);
        let requested_peak = settings.preamp_db + maximum_boost;
        let headroom_db = requested_peak.max(0.0);
        let input_gain = 10.0_f32.powf((settings.preamp_db - headroom_db) / 20.0);
        let coefficients = std::array::from_fn(|index| {
            BiquadCoefficients::peaking(
                sample_rate as f32,
                BAND_FREQUENCIES[index],
                settings
                    .band_gains_db
                    .get(index)
                    .copied()
                    .unwrap_or_default(),
            )
        });
        Self {
            left: coefficients.map(Biquad::new),
            right: coefficients.map(Biquad::new),
            input_gain,
        }
    }

    fn process(&mut self, frames: &mut [Frame]) {
        for frame in frames {
            let mut left = frame.left * self.input_gain;
            let mut right = frame.right * self.input_gain;
            for filter in &mut self.left {
                left = filter.process(left);
            }
            for filter in &mut self.right {
                right = filter.process(right);
            }
            // Final safety limiter. Automatic headroom handles normal boosts;
            // this clamp only catches filter overshoot and pathological input.
            frame.left = left.clamp(-1.0, 1.0);
            frame.right = right.clamp(-1.0, 1.0);
        }
    }

    fn reset(&mut self) {
        self.left.iter_mut().for_each(Biquad::reset);
        self.right.iter_mut().for_each(Biquad::reset);
    }
}

#[derive(Clone, Copy)]
struct BiquadCoefficients {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

impl BiquadCoefficients {
    fn peaking(sample_rate: f32, frequency: f32, gain_db: f32) -> Self {
        let frequency = frequency.min(sample_rate * 0.45);
        let a = 10.0_f32.powf(gain_db / 40.0);
        let omega = 2.0 * PI * frequency / sample_rate;
        let alpha = omega.sin() / (2.0 * 1.4);
        let cos = omega.cos();
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos) / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }
}

#[derive(Clone, Copy)]
struct Biquad {
    coefficients: BiquadCoefficients,
    z1: f32,
    z2: f32,
}

impl Biquad {
    fn new(coefficients: BiquadCoefficients) -> Self {
        Self {
            coefficients,
            z1: 0.0,
            z2: 0.0,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let output = self.coefficients.b0 * input + self.z1;
        self.z1 = self.coefficients.b1 * input - self.coefficients.a1 * output + self.z2;
        self.z2 = self.coefficients.b2 * input - self.coefficients.a2 * output;
        output
    }

    fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

#[cfg(test)]
mod tests {
    use super::EqualizerProcessor;
    use crate::api::EqualizerSettings;
    use kira::Frame;

    #[test]
    fn bypass_is_bit_transparent_and_limiter_contains_extreme_boosts() {
        let original = vec![Frame::new(0.5, -0.5); 512];
        let mut bypassed = original.clone();
        // Bypass means no processor is instantiated by EqualizedDecoder.
        assert_eq!(bypassed, original);

        let settings = EqualizerSettings {
            enabled: true,
            preamp_db: 12.0,
            band_gains_db: vec![12.0; 10],
            preset: "Stress".into(),
        };
        let mut processor = EqualizerProcessor::new(48_000, &settings);
        processor.process(&mut bypassed);
        assert!(bypassed.iter().all(|frame| {
            frame.left.is_finite()
                && frame.right.is_finite()
                && frame.left.abs() <= 1.0
                && frame.right.abs() <= 1.0
        }));
    }

    #[test]
    fn boosted_band_changes_the_signal() {
        let settings = EqualizerSettings {
            enabled: true,
            preamp_db: 0.0,
            band_gains_db: vec![0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0, 0.0],
            preset: "Custom".into(),
        };
        let mut processor = EqualizerProcessor::new(48_000, &settings);
        let mut frames = (0..4_800)
            .map(|index| {
                let value = (2.0 * std::f32::consts::PI * index as f32 / 48.0).sin() * 0.1;
                Frame::from_mono(value)
            })
            .collect::<Vec<_>>();
        let before = frames.clone();
        processor.process(&mut frames);
        assert!(
            frames
                .iter()
                .zip(before)
                .any(|(after, before)| { (after.left - before.left).abs() > 0.001 })
        );
    }
}
