// prod.keys: "name = hex" lines. Values stay in memory: nothing here prints, formats or logs them,
// and the type has no Debug impl so a stray {:?} cannot either. Only key names are ever shown.
use std::collections::HashMap;
use std::path::Path;

pub struct Keys {
    map: HashMap<String, Vec<u8>>,
}

impl Keys {
    pub fn load(path: &Path) -> Result<Keys, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let mut map = HashMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
                continue;
            }
            let Some((name, value)) = line.split_once('=') else { continue };
            if let Some(bytes) = unhex(value.trim()) {
                map.insert(name.trim().to_ascii_lowercase(), bytes);
            }
        }
        if map.is_empty() {
            return Err(format!("{} holds no keys", path.display()));
        }
        Ok(Keys { map })
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// A 16-byte key, or None when it is missing or the wrong size.
    pub fn key16(&self, name: &str) -> Option<[u8; 16]> {
        self.map.get(name).and_then(|v| v.as_slice().try_into().ok())
    }

    /// A 32-byte key (header_key), or None.
    pub fn key32(&self, name: &str) -> Option<[u8; 32]> {
        self.map.get(name).and_then(|v| v.as_slice().try_into().ok())
    }

    /// The highest master key revision present (master_key_XX), for the summary line.
    pub fn newest_master_key(&self) -> Option<u8> {
        self.map
            .keys()
            .filter_map(|k| k.strip_prefix("master_key_"))
            .filter_map(|n| u8::from_str_radix(n, 16).ok())
            .max()
    }
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 || s.is_empty() {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}
