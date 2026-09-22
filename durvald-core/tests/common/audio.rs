use std::io;
use std::path::{Path, PathBuf};

use super::filesystem::TestFs;

fn one_second_silent_wav() -> Vec<u8> {
    let sample_rate = 8_000u32;
    let channels = 1u16;
    let bits_per_sample = 16u16;
    let bytes_per_sample = u32::from(bits_per_sample / 8);

    let data_len = sample_rate * u32::from(channels) * bytes_per_sample;

    let byte_rate = sample_rate * u32::from(channels) * bytes_per_sample;

    let block_align = channels * (bits_per_sample / 8);

    let mut wav = Vec::with_capacity(44 + data_len as usize);

    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");

    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());

    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());

    wav.resize(44 + data_len as usize, 0);

    wav
}

impl TestFs {
    pub fn write_silent_wav(&self, relative_path: impl AsRef<Path>) -> io::Result<PathBuf> {
        self.write_library_file(relative_path, &one_second_silent_wav())
    }
}
