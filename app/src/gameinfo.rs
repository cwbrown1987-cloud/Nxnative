// What the window shows about the game in a folder: its name and icon, from the last conversion's output
// (the extracted control data's icon.jpg, the app's CFBundleName) or else from the base NSP's file name.
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Default)]
pub struct GameInfo {
    pub name: String,
    pub icon: Option<PathBuf>,
}

pub fn read(dir: &Path) -> GameInfo {
    let build = std::fs::read_dir(dir)
        .ok()
        .and_then(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).find(|p| p.is_dir() && p.file_name().is_some_and(|n| n.to_string_lossy().ends_with("_build"))));
    // the newest extracted version's icon (nx_extract writes <version>/icon.jpg)
    let icon = build.and_then(|b| {
        let mut icons: Vec<PathBuf> = std::fs::read_dir(b.join("extract")).ok()?.filter_map(|e| e.ok().map(|e| e.path().join("icon.jpg"))).filter(|p| p.is_file()).collect();
        icons.sort_by_key(|p| p.metadata().and_then(|m| m.modified()).ok());
        icons.pop()
    });
    let from_app = crate::engine::apps_in(dir).first().and_then(|(app, _)| {
        let o = Command::new("/usr/bin/plutil").args(["-extract", "CFBundleName", "raw", "-o", "-"]).arg(app.join("Contents/Info.plist")).output().ok()?;
        let n = String::from_utf8_lossy(&o.stdout).trim().to_string();
        (o.status.success() && !n.is_empty()).then_some(n)
    });
    let from_nsp = || {
        crate::nsp::game_files(dir).into_iter().find_map(|p| {
            let n = p.file_stem()?.to_string_lossy().to_string();
            let name = n.split(" [").next().unwrap_or(&n).trim().to_string();
            (n.contains("000]") || !n.contains('[')).then_some(name)
        })
    };
    GameInfo { name: from_app.or_else(from_nsp).unwrap_or_else(|| dir.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()), icon }
}

pub fn load_icon(path: &Path) -> Option<eframe::egui::ColorImage> {
    let img = image::open(path).ok()?.to_rgba8();
    let size = [img.width() as usize, img.height() as usize];
    Some(eframe::egui::ColorImage::from_rgba_unmultiplied(size, img.as_raw()))
}
