use std::f32::consts::TAU;

pub(crate) const SPECTRUM_BANDS: usize = 16;
pub(crate) const SPECTRUM_SAMPLES: usize = 512;

/// Computes a small logarithmic spectrum on the caller thread. Samples reach
/// this function through a lock-free tap in the renderer; no FFT or allocation
/// occurs in the real-time audio callback.
pub(crate) fn spectrum(samples: &[f32]) -> Vec<f32> {
    if samples.len() < 32 {
        return vec![0.0; SPECTRUM_BANDS];
    }
    let length = samples.len() as f32;
    let maximum_bin = samples.len() / 2;
    let mut bands = Vec::with_capacity(SPECTRUM_BANDS);
    for band in 0..SPECTRUM_BANDS {
        let progress = band as f32 / (SPECTRUM_BANDS - 1) as f32;
        let bin = ((maximum_bin as f32).powf(progress)).round() as usize;
        let bin = bin.clamp(1, maximum_bin);
        let mut real = 0.0;
        let mut imaginary = 0.0;
        for (index, sample) in samples.iter().copied().enumerate() {
            let window = 0.5 - 0.5 * (TAU * index as f32 / (length - 1.0)).cos();
            let phase = TAU * bin as f32 * index as f32 / length;
            real += sample * window * phase.cos();
            imaginary -= sample * window * phase.sin();
        }
        let magnitude = (real.mul_add(real, imaginary * imaginary)).sqrt() * 2.0 / length;
        let decibels = 20.0 * magnitude.max(0.001).log10();
        bands.push(((decibels + 60.0) / 60.0).clamp(0.0, 1.0));
    }
    bands
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spectrum_is_bounded_and_identifies_energy() {
        let samples = (0..SPECTRUM_SAMPLES)
            .map(|index| (TAU * 12.0 * index as f32 / SPECTRUM_SAMPLES as f32).sin() * 0.8)
            .collect::<Vec<_>>();
        let bands = spectrum(&samples);
        assert_eq!(bands.len(), SPECTRUM_BANDS);
        assert!(bands.iter().all(|value| (0.0..=1.0).contains(value)));
        assert!(bands.iter().copied().fold(0.0, f32::max) > 0.5);
        assert_eq!(spectrum(&[]), vec![0.0; SPECTRUM_BANDS]);
    }
}
