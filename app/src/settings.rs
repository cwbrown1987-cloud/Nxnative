// Settings kept between runs in ~/Library/Application Support/NxNative Converter/settings.json.
// Paths only: the keys file's location is remembered, never its content.
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    pub repo: Option<PathBuf>,
    pub python: Option<PathBuf>,
    pub keys: Option<PathBuf>,
    pub game_dir: Option<PathBuf>,
    /// codesign identity; None = ad-hoc
    pub sign_identity: Option<String>,
    /// where new apps go; None = the game folder
    #[serde(default)]
    pub out_dir: Option<PathBuf>,
}

pub fn support_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_else(|| PathBuf::from("/tmp")).join("NxNative Converter")
}

impl Settings {
    pub fn load() -> Settings {
        std::fs::read(support_dir().join("settings.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let d = support_dir();
        let _ = std::fs::create_dir_all(&d);
        if let Ok(b) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(d.join("settings.json"), b);
        }
    }
}
