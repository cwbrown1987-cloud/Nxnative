// The window: a sidebar (Convert, Builds, Toolchain, Settings) over the same steps as the command line.
use crate::convert::{self, Shared, StageDone};
use crate::engine::{self, Version};
use crate::gameinfo::{self, GameInfo};
use crate::nsp::{self, Validation};
use crate::prereq::{self, Check, Env};
use crate::settings::Settings;
use eframe::egui::{self, Align, Color32, CornerRadius, FontId, Layout, Margin, RichText, Stroke, Vec2};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const BG: Color32 = Color32::from_rgb(24, 25, 28);
const SIDEBAR: Color32 = Color32::from_rgb(30, 31, 35);
const CARD: Color32 = Color32::from_rgb(34, 35, 40);
const FIELD: Color32 = Color32::from_rgb(28, 29, 33);
const LINE: Color32 = Color32::from_rgb(52, 54, 60);
const TEXT: Color32 = Color32::from_rgb(232, 233, 236);
const DIM: Color32 = Color32::from_rgb(150, 152, 160);
const BLUE: Color32 = Color32::from_rgb(28, 110, 240);
const GREEN: Color32 = Color32::from_rgb(52, 199, 89);
const RED: Color32 = Color32::from_rgb(255, 69, 58);
const GREY: Color32 = Color32::from_rgb(110, 112, 120);

/// The script's stage names, as the window shows them.
const STAGES: [(&str, &str); 7] = [
    ("build nx_extract", "Extract tools"),
    ("extract", "Extract game files"),
    ("rewrite", "Rewrite executable"),
    ("shader split", "Split shaders"),
    ("Mac shaders", "Compile Metal shaders"),
    ("Mac host", "Build Mac host"),
    ("Mac app", "Package Mac app"),
];

fn friendly(name: &str) -> String {
    STAGES.iter().find(|(k, _)| name.starts_with(k)).map(|(_, v)| v.to_string()).unwrap_or_else(|| {
        let mut c = name.chars();
        c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
    })
}

pub fn run() {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1240.0, 960.0]).with_min_inner_size([980.0, 640.0]).with_title("NxNative Converter"),
        ..Default::default()
    };
    let _ = eframe::run_native("NxNative Converter", opts, Box::new(|cc| Ok(Box::new(App::new(&cc.egui_ctx)))));
}

type Slot<T> = Arc<Mutex<Option<T>>>;

#[derive(PartialEq, Clone, Copy)]
enum Page {
    Convert,
    Builds,
    Toolchain,
    Settings,
}

struct App {
    page: Page,
    s: Settings,
    checks: Slot<(Vec<Check>, Env)>,
    checking: bool,
    validation: Slot<Validation>,
    validating: bool,
    validated_for: Option<(PathBuf, PathBuf)>,
    conv: Shared,
    identities: Vec<String>,
    engine: Slot<Version>,
    engine_msg: Slot<(bool, String)>,
    game: Option<(PathBuf, GameInfo)>,
    icon: Option<(PathBuf, egui::TextureHandle)>,
    was_running: bool,
    /// NXC_SNAPSHOT=<png> (and NXC_PAGE=builds/toolchain/settings): save a picture of the window a few seconds after start and quit (for checking the layout without a screen capture)
    snapshot: Option<(PathBuf, std::time::Instant, bool)>,
}

impl App {
    fn new(ctx: &egui::Context) -> App {
        style(ctx);
        let mut a = App {
            page: Page::Convert,
            s: Settings::load(),
            checks: Default::default(),
            checking: false,
            validation: Default::default(),
            validating: false,
            validated_for: None,
            conv: Default::default(),
            identities: prereq::signing_identities(),
            engine: Default::default(),
            engine_msg: Default::default(),
            game: None,
            icon: None,
            was_running: false,
            snapshot: std::env::var("NXC_SNAPSHOT").ok().map(|v| (PathBuf::from(v), std::time::Instant::now(), false)),
        };
        if let Ok(p) = std::env::var("NXC_PAGE") {
            a.page = match p.as_str() {
                "builds" => Page::Builds,
                "toolchain" => Page::Toolchain,
                "settings" => Page::Settings,
                _ => Page::Convert,
            };
        }
        a.recheck(ctx);
        if a.s.game_dir.is_some() && a.s.keys.is_some() {
            a.validate(ctx);
        }
        a
    }

    fn recheck(&mut self, ctx: &egui::Context) {
        self.checking = true;
        let (slot, s, ctx) = (self.checks.clone(), self.s.clone(), ctx.clone());
        std::thread::spawn(move || {
            let r = prereq::check_all(&s);
            *slot.lock().unwrap() = Some(r);
            ctx.request_repaint();
        });
    }

    fn refresh_engine(&self, repo: Option<PathBuf>) {
        let slot = self.engine.clone();
        std::thread::spawn(move || *slot.lock().unwrap() = repo.and_then(|r| engine::current(&r)));
    }

    fn engine_action(&self, repo: PathBuf, update: bool, ctx: &egui::Context) {
        let (msg, ver, ctx) = (self.engine_msg.clone(), self.engine.clone(), ctx.clone());
        *msg.lock().unwrap() = Some((true, if update { "Updating…".into() } else { "Checking…".into() }));
        std::thread::spawn(move || {
            let r = if update {
                engine::update(&repo).map(|_| "Updated".to_string())
            } else {
                engine::check_updates(&repo).map(|(n, _)| if n == 0 { "Up to date".into() } else { format!("{n} update(s) available") })
            };
            *msg.lock().unwrap() = Some(match r {
                Ok(m) => (true, m),
                Err(e) => (false, e),
            });
            *ver.lock().unwrap() = engine::current(&repo);
            ctx.request_repaint();
        });
    }

    fn validate(&mut self, ctx: &egui::Context) {
        let (Some(dir), Some(keys)) = (self.s.game_dir.clone(), self.s.keys.clone()) else { return };
        self.validating = true;
        *self.validation.lock().unwrap() = None;
        self.validated_for = Some((dir.clone(), keys.clone()));
        self.game = Some((dir.clone(), gameinfo::read(&dir)));
        let (slot, ctx) = (self.validation.clone(), ctx.clone());
        std::thread::spawn(move || {
            let v = nsp::validate(&dir, &keys);
            *slot.lock().unwrap() = Some(v);
            ctx.request_repaint();
        });
    }

    fn set_game_dir(&mut self, dir: PathBuf, ctx: &egui::Context) {
        // prod.keys beside the game files is the usual layout: take it when no keys file is chosen yet
        let beside = dir.join("prod.keys");
        if beside.is_file() && self.s.keys.as_ref().is_none_or(|k| !k.is_file()) {
            self.s.keys = Some(beside);
        }
        self.s.game_dir = Some(dir);
        self.s.save();
        self.validate(ctx);
    }

    fn start(&mut self, ctx: &egui::Context, env: Env, rebuild: Option<PathBuf>) {
        let dir = self.s.game_dir.clone().unwrap();
        let name = self.game.as_ref().map(|(_, g)| g.name.clone()).unwrap_or_default();
        let out = self.s.out_dir.clone().filter(|o| *o != dir && !name.is_empty()).map(|o| o.join(format!("{}.app", name.replace([':', '/'], " - "))));
        let job = convert::Job { game_dir: dir, keys: self.s.keys.clone().unwrap(), sign: self.s.sign_identity.clone(), env, rebuild, out };
        let c = ctx.clone();
        convert::start(job, self.conv.clone(), move || c.request_repaint());
    }
}

fn style(ctx: &egui::Context) {
    let mut v = egui::Visuals::dark();
    v.panel_fill = BG;
    v.window_fill = CARD;
    v.extreme_bg_color = FIELD;
    v.override_text_color = Some(TEXT);
    v.widgets.inactive.weak_bg_fill = Color32::from_rgb(48, 50, 56);
    v.widgets.inactive.bg_fill = Color32::from_rgb(48, 50, 56);
    v.widgets.hovered.weak_bg_fill = Color32::from_rgb(60, 62, 70);
    v.widgets.active.weak_bg_fill = Color32::from_rgb(70, 72, 80);
    for w in [&mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active, &mut v.widgets.noninteractive] {
        w.corner_radius = CornerRadius::same(8);
    }
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, LINE);
    v.selection.bg_fill = BLUE;
    ctx.set_visuals(v);
    ctx.global_style_mut(|s| {
        s.spacing.item_spacing = Vec2::new(10.0, 8.0);
        s.spacing.button_padding = Vec2::new(14.0, 7.0);
        s.text_styles.insert(egui::TextStyle::Body, FontId::proportional(15.0));
        s.text_styles.insert(egui::TextStyle::Button, FontId::proportional(15.0));
        s.text_styles.insert(egui::TextStyle::Small, FontId::proportional(12.5));
        s.text_styles.insert(egui::TextStyle::Heading, FontId::proportional(30.0));
    });
}

/// A filled disc with a white sign: green tick, red cross, grey dash.
fn badge(ui: &mut egui::Ui, state: Option<bool>, size: f32) {
    let (t, c) = match state {
        Some(true) => ("✔", GREEN),
        Some(false) => ("✘", RED),
        None => ("–", GREY),
    };
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), egui::Sense::hover());
    ui.painter().circle_filled(rect.center(), size / 2.0, c);
    ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, t, FontId::proportional(size * 0.62), Color32::WHITE);
}

fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::new()
        .fill(CARD)
        .stroke(Stroke::new(1.0, LINE))
        .corner_radius(CornerRadius::same(12))
        .inner_margin(Margin::same(20))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.vertical(add).inner
        })
        .inner
}

fn title(ui: &mut egui::Ui, t: &str, sub: &str) {
    ui.label(RichText::new(t).size(21.0).strong());
    if !sub.is_empty() {
        ui.label(RichText::new(sub).color(DIM));
    }
    ui.add_space(6.0);
}

/// A read-only path box like a text field, with a Browse button on its right.
fn path_row(ui: &mut egui::Ui, label: &str, label_w: f32, value: &str, enabled: bool) -> bool {
    let mut clicked = false;
    ui.horizontal(|ui| {
        ui.add_sized([label_w, 34.0], egui::Label::new(label));
        let bw = 110.0;
        let w = (ui.available_width() - bw - 10.0).max(80.0);
        egui::Frame::new().fill(FIELD).stroke(Stroke::new(1.0, LINE)).corner_radius(CornerRadius::same(8)).inner_margin(Margin::symmetric(12, 8)).show(ui, |ui| {
            ui.set_width(w - 24.0);
            ui.add(egui::Label::new(RichText::new(value).color(if value.is_empty() { DIM } else { TEXT })).truncate());
        });
        clicked = ui.add_enabled(enabled, egui::Button::new("Browse…").min_size(Vec2::new(bw, 34.0))).clicked();
    });
    clicked
}

fn tilde(p: &Path) -> String {
    let s = p.display().to_string();
    match dirs::home_dir() {
        Some(h) if s.starts_with(&*h.to_string_lossy()) => format!("~{}", &s[h.to_string_lossy().len()..]),
        _ => s,
    }
}

fn mmss(s: u64) -> String {
    format!("{}:{:02}", s / 60, s % 60)
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = &ui.ctx().clone();
        if self.checking && self.checks.lock().unwrap().is_some() {
            self.checking = false;
            let repo = self.checks.lock().unwrap().as_ref().and_then(|(_, e)| e.repo.clone());
            self.refresh_engine(repo);
        }
        if self.validating && self.validation.lock().unwrap().is_some() {
            self.validating = false;
        }
        let checks = self.checks.lock().unwrap().clone();
        let passed = checks.as_ref().map(|(c, _)| c.iter().filter(|c| c.ok).count()).unwrap_or(0);
        let all_ok = checks.as_ref().is_some_and(|(c, _)| c.iter().all(|c| c.ok || c.optional));
        let running = self.conv.lock().unwrap().running;
        if running {
            ctx.request_repaint_after(std::time::Duration::from_millis(500));
        }
        if self.was_running && !running {
            // a build just ended: the app, its name and icon may be new
            if let Some(d) = self.s.game_dir.clone() {
                self.game = Some((d.clone(), gameinfo::read(&d)));
            }
        }
        self.was_running = running;
        // NXC_AUTOBUILD=1 with NXC_SNAPSHOT: build once the folder validates, and take the picture when it ends
        let autobuild = std::env::var_os("NXC_AUTOBUILD").is_some();
        if autobuild && self.snapshot.is_some() && !running && self.conv.lock().unwrap().result.is_none() {
            let valid = self.validation.lock().unwrap().as_ref().is_some_and(|v| v.ok);
            if let (true, Some((_, env))) = (valid && all_ok, checks.clone()) {
                self.start(ctx, env, None);
            }
        }
        let build_done = !autobuild || self.conv.lock().unwrap().result.is_some();
        if let Some((path, t0, sent)) = &mut self.snapshot {
            ctx.request_repaint_after(std::time::Duration::from_millis(200));
            if !*sent && t0.elapsed().as_secs() >= 6 && build_done {
                *sent = true;
                let p = path.clone();
                ctx.request_screenshot(move |img| {
                    let raw: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_array()).collect();
                    let _ = image::save_buffer(&p, &raw, img.size[0] as u32, img.size[1] as u32, image::ColorType::Rgba8);
                    std::process::exit(0);
                });
            }
        }


        egui::Panel::left("nav").exact_size(250.0).resizable(false).frame(egui::Frame::new().fill(SIDEBAR).inner_margin(Margin::same(14))).show(ui, |ui| {
            ui.add_space(6.0);
            for (page, icon, label) in [(Page::Convert, "🎮", "Convert"), (Page::Builds, "🕘", "Builds"), (Page::Toolchain, "🔧", "Toolchain"), (Page::Settings, "⚙", "Settings")] {
                let sel = self.page == page;
                let b = egui::Button::new(RichText::new(format!("{icon}   {label}")).size(16.0).color(if sel { Color32::WHITE } else { TEXT }))
                    .fill(if sel { BLUE } else { Color32::TRANSPARENT })
                    .stroke(Stroke::NONE)
                    .min_size(Vec2::new(ui.available_width(), 42.0));
                if ui.add(b).clicked() {
                    self.page = page;
                }
            }
            ui.with_layout(Layout::bottom_up(Align::LEFT), |ui| {
                ui.add_space(6.0);
                let total = checks.as_ref().map(|(c, _)| c.len()).unwrap_or(0);
                let r = ui
                    .horizontal(|ui| {
                        badge(ui, checks.as_ref().map(|_| passed == total).or(Some(false)).filter(|_| !self.checking).or(None), 20.0);
                        ui.label(RichText::new(format!("{passed} of {total} checks passed")).color(DIM));
                    })
                    .response;
                ui.horizontal(|ui| {
                    badge(ui, if self.checking { None } else { Some(all_ok) }, 20.0);
                    ui.label(if self.checking { "Checking toolchain…" } else if all_ok { "Toolchain ready" } else { "Toolchain incomplete" });
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.add(egui::Button::new("›").frame(false)).clicked() {
                            self.page = Page::Toolchain;
                        }
                    });
                });
                if r.interact(egui::Sense::click()).clicked() {
                    self.page = Page::Toolchain;
                }
                ui.separator();
            });
        });

        egui::CentralPanel::default().frame(egui::Frame::new().fill(BG).inner_margin(Margin::symmetric(26, 18))).show(ui, |ui| {
            egui::ScrollArea::vertical().auto_shrink([false; 2]).show(ui, |ui| match self.page {
                Page::Convert => self.convert_page(ui, ctx, &checks, all_ok, running),
                Page::Builds => self.builds_page(ui, ctx, &checks, all_ok, running),
                Page::Toolchain => self.toolchain_page(ui, ctx, &checks),
                Page::Settings => self.settings_page(ui, ctx, &checks),
            });
        });
    }
}

impl App {
    fn convert_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, checks: &Option<(Vec<Check>, Env)>, all_ok: bool, running: bool) {
        ui.label(RichText::new("Convert game").size(32.0).strong());
        ui.label(RichText::new("Build a native Mac app from your game files.").size(17.0).color(DIM));
        ui.add_space(14.0);

        let validation = self.validation.lock().unwrap().clone();
        let current = self.validated_for == self.s.game_dir.clone().zip(self.s.keys.clone());
        let valid = current && validation.as_ref().is_some_and(|v| v.ok);
        let ver = self.engine.lock().unwrap().clone();
        let repo = checks.as_ref().and_then(|(_, e)| e.repo.clone());
        let env = checks.as_ref().map(|(_, e)| e.clone());
        let game = self.game.as_ref().filter(|(d, _)| Some(d) == self.s.game_dir.as_ref()).map(|(_, g)| g.clone());

        let full = ui.available_width();
        let left_w = (full * 0.52).floor();
        ui.horizontal_top(|ui| {
            // ---- game files
            ui.allocate_ui_with_layout(Vec2::new(left_w, 0.0), Layout::top_down(Align::LEFT), |ui| {
                card(ui, |ui| {
                    title(ui, "Game files", "Select your game directory and prod.keys file.");
                    let dir_txt = self.s.game_dir.as_deref().map(tilde).unwrap_or_default();
                    if path_row(ui, "Game folder", 95.0, &dir_txt, !running) {
                        if let Some(d) = rfd::FileDialog::new().pick_folder() {
                            self.set_game_dir(d, ctx);
                        }
                    }
                    let keys_txt = self.s.keys.as_ref().map(|k| if k.parent() == self.s.game_dir.as_deref() { k.file_name().unwrap().to_string_lossy().to_string() } else { tilde(k) }).unwrap_or_default();
                    if path_row(ui, "Keys file", 95.0, &keys_txt, !running) {
                        if let Some(f) = rfd::FileDialog::new().add_filter("keys", &["keys"]).pick_file() {
                            self.s.keys = Some(f);
                            self.s.save();
                            self.validate(ctx);
                        }
                    }
                    ui.add_space(2.0);
                    if self.validating {
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.label(RichText::new("Checking the game files against your keys…").color(DIM));
                        });
                    } else if let Some(v) = validation.as_ref().filter(|_| current) {
                        let keys_line = v.summary.first();
                        ui.horizontal(|ui| {
                            badge(ui, Some(keys_line.is_some_and(|l| l.ok) && v.ok), 22.0);
                            let txt = keys_line.map(|l| l.text.replace("prod.keys read: ", "")).unwrap_or_default();
                            ui.label(RichText::new(if v.ok { format!("Keys validated · {txt}") } else { format!("Validation failed · {txt}") }).color(DIM));
                        });
                        for l in v.summary.iter().skip(1).filter(|l| !l.ok) {
                            ui.label(RichText::new(&l.text).color(RED));
                        }
                    } else if self.s.game_dir.is_some() && self.s.keys.is_some() && ui.button("Validate").clicked() {
                        self.validate(ctx);
                    }
                    ui.add_space(6.0);
                    ui.separator();

                    // detected files
                    if let Some(v) = validation.as_ref().filter(|_| current) {
                        ui.label(RichText::new(game.as_ref().map(|g| g.name.clone()).unwrap_or_else(|| "Game".into())).size(21.0).strong());
                        ui.label(RichText::new(format!("Detected game files ({} file{})", v.files.len(), if v.files.len() == 1 { "" } else { "s" })).color(DIM));
                        ui.add_space(4.0);
                        egui::Frame::new().fill(FIELD).stroke(Stroke::new(1.0, LINE)).corner_radius(CornerRadius::same(8)).inner_margin(Margin::symmetric(14, 8)).show(ui, |ui| {
                            ui.set_width(ui.available_width());
                            let w = ui.available_width();
                            let cols = [w * 0.47, w * 0.30];
                            ui.horizontal(|ui| {
                                cell(ui, cols[0], RichText::new("File").small().color(DIM));
                                cell(ui, cols[1], RichText::new("Type").small().color(DIM));
                                ui.label(RichText::new("Status").small().color(DIM));
                            });
                            for f in &v.files {
                                ui.separator();
                                let r = ui.horizontal(|ui| {
                                    cell(ui, cols[0], RichText::new(short_name(&f.name)));
                                    let mut role = f.role.clone();
                                    if let Some(c) = role.get_mut(..1) {
                                        c.make_ascii_uppercase();
                                    }
                                    cell(ui, cols[1], RichText::new(role));
                                    badge(ui, Some(f.ok), 18.0);
                                    ui.label(RichText::new(if f.ok { "Ready" } else { "Failed" }).color(if f.ok { GREEN } else { RED }));
                                });
                                let tip: Vec<String> = f.lines.iter().map(|l| format!("{} {}", if l.ok { "✔" } else { "✘" }, l.text)).collect();
                                r.response.on_hover_text(format!("{}\n{}", f.name, tip.join("\n")));
                                for l in f.lines.iter().filter(|l| !l.ok) {
                                    ui.label(RichText::new(&l.text).small().color(RED));
                                }
                            }
                        });
                        ui.add_space(6.0);
                        ui.separator();
                    }

                    // engine
                    ui.label(RichText::new("Engine").size(21.0).strong());
                    ui.label(RichText::new("NxNative engine version").color(DIM));
                    ui.horizontal(|ui| {
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if let Some(r) = &repo {
                                let msg = self.engine_msg.lock().unwrap().clone();
                                let has_updates = msg.as_ref().is_some_and(|(ok, m)| *ok && m.contains("available"));
                                if has_updates {
                                    if ui.add_enabled(!running && !ver.as_ref().is_some_and(|v| v.dirty), egui::Button::new("Update engine").min_size(Vec2::new(0.0, 34.0))).clicked() {
                                        self.engine_action(r.clone(), true, ctx);
                                    }
                                } else if ui.add_enabled(!running, egui::Button::new("Check for updates…").min_size(Vec2::new(0.0, 34.0))).clicked() {
                                    self.engine_action(r.clone(), false, ctx);
                                }
                                if let Some(v) = &ver {
                                    let (state, col) = match &msg {
                                        Some((false, _)) => ("Check failed".to_string(), RED),
                                        Some((true, m)) => (m.clone(), if has_updates { BLUE } else { GREEN }),
                                        None => ("Current".to_string(), GREEN),
                                    };
                                    let l = ui.label(RichText::new(format!("{}{} · {state}", v.short(), if v.dirty { "+" } else { "" })).color(col));
                                    l.on_hover_text(format!("{} on {}\n{}", r.display(), v.branch, msg.as_ref().map(|(_, m)| m.clone()).unwrap_or_default()));
                                    badge(ui, Some(!matches!(msg, Some((false, _)))), 22.0);
                                }
                            } else {
                                ui.label(RichText::new("no repository").color(RED));
                            }
                        });
                    });
                });
            });

            // ---- mac app
            ui.allocate_ui_with_layout(Vec2::new(ui.available_width(), 0.0), Layout::top_down(Align::LEFT), |ui| {
                card(ui, |ui| {
                    title(ui, "Mac app", "Build settings for your native Mac application.");
                    ui.horizontal(|ui| {
                        let icon_path = game.as_ref().and_then(|g| g.icon.clone());
                        if let Some(p) = icon_path {
                            if self.icon.as_ref().map(|(ip, _)| ip != &p).unwrap_or(true) {
                                if let Some(img) = gameinfo::load_icon(&p) {
                                    self.icon = Some((p.clone(), ctx.load_texture("game-icon", img, egui::TextureOptions::LINEAR)));
                                }
                            }
                        } else {
                            self.icon = None;
                        }
                        let size = Vec2::splat(120.0);
                        match &self.icon {
                            Some((_, tex)) => {
                                ui.add(egui::Image::new(tex).fit_to_exact_size(size).corner_radius(CornerRadius::same(22)));
                            }
                            None => {
                                let (rect, _) = ui.allocate_exact_size(size, egui::Sense::hover());
                                ui.painter().rect_filled(rect, CornerRadius::same(22), Color32::from_rgb(48, 50, 56));
                                ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, "🎮", FontId::proportional(44.0), DIM);
                            }
                        }
                        ui.add_space(8.0);
                        ui.vertical(|ui| {
                            ui.add_space(14.0);
                            ui.label(RichText::new(game.as_ref().map(|g| g.name.clone()).unwrap_or_else(|| "No game selected".into())).size(23.0).strong());
                            ui.label(RichText::new("Apple Silicon · Metal").color(DIM).size(16.0));
                            ui.label(RichText::new("A native macOS version built with NxNative.").color(DIM));
                        });
                    });
                    ui.add_space(10.0);
                    let out_txt = self.s.out_dir.clone().or(self.s.game_dir.clone()).as_deref().map(tilde).unwrap_or_default();
                    if path_row(ui, "Output folder", 105.0, &out_txt, !running) {
                        if let Some(d) = rfd::FileDialog::new().pick_folder() {
                            self.s.out_dir = if Some(&d) == self.s.game_dir.as_ref() { None } else { Some(d) };
                            self.s.save();
                        }
                    }
                    ui.add_space(6.0);
                    let ready = all_ok && valid && !running;
                    let btn = egui::Button::new(RichText::new(if running { "⏳  Building…" } else { "🔨  Build Mac app" }).size(17.0).strong().color(Color32::WHITE))
                        .fill(if ready || running { BLUE } else { Color32::from_rgb(40, 60, 100) })
                        .min_size(Vec2::new(ui.available_width(), 50.0));
                    let r = ui.add_enabled(ready, btn);
                    if r.clicked() {
                        self.start(ctx, env.clone().unwrap(), None);
                    }
                    if !ready && !running {
                        r.on_disabled_hover_text(if !all_ok { "Some toolchain checks failed: see Toolchain" } else { "Choose a game folder and keys that validate" });
                    }
                    if running && ui.add(egui::Button::new("Stop build").min_size(Vec2::new(ui.available_width(), 30.0))).clicked() {
                        convert::cancel(&self.conv);
                    }
                    ui.add_space(8.0);
                    ui.separator();

                    // latest build of this folder
                    let dir = self.s.game_dir.clone();
                    let st = self.conv.lock().unwrap();
                    let err = st.result.as_ref().and_then(|r| r.as_ref().err().cloned());
                    drop(st);
                    let apps = dir.as_deref().map(engine::apps_in).unwrap_or_default();
                    let latest = apps.iter().max_by_key(|(a, _)| a.metadata().and_then(|m| m.modified()).ok()).cloned();
                    if let Some(e) = err {
                        ui.horizontal(|ui| {
                            badge(ui, Some(false), 28.0);
                            ui.vertical(|ui| {
                                ui.label(RichText::new("Build failed").size(17.0).strong());
                                ui.add(egui::Label::new(RichText::new(e).color(RED)).wrap());
                            });
                        });
                    }
                    if let Some((app, b)) = latest {
                        let up_to_date = matches!((&b, &ver), (Some(b), Some(v)) if b.engine.commit == v.commit && !v.dirty);
                        ui.horizontal(|ui| {
                            badge(ui, Some(up_to_date), 28.0);
                            ui.vertical(|ui| {
                                ui.label(RichText::new(if up_to_date { "Latest build ready" } else { "Built on an older engine" }).size(17.0).strong());
                                match &b {
                                    Some(b) => {
                                        ui.label(RichText::new(format!("Built on {}", b.built_at.replace(' ', " at "))).color(DIM));
                                        ui.add(egui::Label::new(RichText::new(format!("{} · {}", b.engine.short(), b.engine.subject)).color(DIM)).truncate()).on_hover_text(format!("{}\n{}", b.engine.subject, app.display()));
                                    }
                                    None => {
                                        ui.label(RichText::new("Engine unknown (built before the converter tracked engines)").color(DIM));
                                    }
                                }
                            });
                        });
                        ui.add_space(6.0);
                        ui.horizontal(|ui| {
                            let w = (ui.available_width() - 10.0) / 2.0;
                            if ui.add(egui::Button::new(RichText::new("▶  Open app").size(16.0)).min_size(Vec2::new(w, 42.0))).clicked() {
                                let _ = std::process::Command::new("/usr/bin/open").arg(&app).spawn();
                            }
                            if ui.add(egui::Button::new(RichText::new("Show in Finder").size(16.0)).min_size(Vec2::new(w, 42.0))).clicked() {
                                let _ = std::process::Command::new("/usr/bin/open").arg("-R").arg(&app).spawn();
                            }
                        });
                        if !up_to_date {
                            if let Some(e) = env.clone() {
                                let label = ver.as_ref().map(|v| format!("Rebuild on {}", v.short())).unwrap_or_else(|| "Rebuild".into());
                                if ui.add_enabled(all_ok && valid && !running, egui::Button::new(label).min_size(Vec2::new(ui.available_width(), 34.0))).on_hover_text("Moves this app to app-backups/ and builds it again on the current engine").clicked() {
                                    self.start(ctx, e, Some(app.clone()));
                                }
                            }
                        }
                    } else if !running {
                        ui.label(RichText::new("No Mac app in this folder yet.").color(DIM));
                    }
                });
            });
        });
        ui.add_space(14.0);
        self.activity(ui, ctx);
    }

    fn activity(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let st = self.conv.lock().unwrap();
        let stages: Vec<StageDone> = st.done_stages.clone();
        let (running, cur, result, log) = (st.running, st.stage.clone(), st.result.clone(), st.log.clone());
        drop(st);
        card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.vertical(|ui| {
                    ui.label(RichText::new("Build activity").size(21.0).strong());
                    ui.label(RichText::new("Converting your game to a native Mac application.").color(DIM));
                });
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui.add_enabled(!log.is_empty(), egui::Button::new("📋  Copy log").min_size(Vec2::new(0.0, 36.0))).clicked() {
                        let mut text: Vec<String> = stages.iter().map(|s| s.line()).collect();
                        text.extend(log.iter().cloned());
                        ctx.copy_text(text.join("\n"));
                    }
                    let n = if running { cur.n } else { stages.last().map(|s| s.n).unwrap_or(STAGES.len() as u64) };
                    let done = stages.iter().filter(|s| s.ok).count();
                    if running || !stages.is_empty() {
                        let ok = !running && result.as_ref().is_some_and(|r| r.is_ok());
                        ui.label(RichText::new(format!("{done} of {n} complete")).color(if ok { GREEN } else { DIM }).size(16.0));
                        if running {
                            ui.spinner();
                        } else {
                            badge(ui, Some(ok), 22.0);
                        }
                    }
                });
            });
            ui.add_space(8.0);

            egui::Frame::new().stroke(Stroke::new(1.0, LINE)).corner_radius(CornerRadius::same(8)).inner_margin(Margin::symmetric(8, 4)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                let rows = if stages.is_empty() && !running { STAGES.len() } else { stages.len() + usize::from(running) };
                for i in 0..rows {
                    if i > 0 {
                        ui.separator();
                    }
                    ui.horizontal(|ui| {
                        let (num, state, name, time, status, col): (u64, Option<bool>, String, String, String, Color32) = if let Some(s) = stages.get(i) {
                            let col = if !s.ok { RED } else if s.reused() { DIM } else { GREEN };
                            (s.k, Some(s.ok), friendly(&s.name), mmss(s.secs), if !s.ok { "Failed".into() } else if s.reused() { "Reused".into() } else { "Complete".into() }, col)
                        } else if running && i == stages.len() {
                            (cur.k, None, friendly(&cur.name), String::new(), String::new(), BLUE)
                        } else {
                            (i as u64 + 1, None, STAGES[i].1.to_string(), "–".into(), "Not run".into(), DIM)
                        };
                        let (rect, _) = ui.allocate_exact_size(Vec2::new(26.0, 24.0), egui::Sense::hover());
                        ui.painter().rect_filled(rect, CornerRadius::same(5), Color32::from_rgb(52, 54, 62));
                        ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, num.to_string(), FontId::proportional(13.0), DIM);
                        if running && i == stages.len() {
                            ui.add_sized([22.0, 22.0], egui::Spinner::new());
                        } else {
                            badge(ui, state, 20.0);
                        }
                        ui.label(&name);
                        if running && i == stages.len() {
                            if !cur.step.is_empty() {
                                ui.label(RichText::new(format!("· {}", cur.step)).color(DIM));
                            }
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                ui.label(RichText::new(&cur.detail).small().color(DIM));
                                let bar = match cur.frac {
                                    Some(f) => egui::ProgressBar::new(f).show_percentage(),
                                    None => egui::ProgressBar::new(0.0).animate(true),
                                };
                                ui.add_sized([220.0, 16.0], bar.fill(BLUE));
                            });
                        } else {
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                ui.add_sized([90.0, 22.0], egui::Label::new(RichText::new(status).color(col)).halign(Align::RIGHT));
                                ui.add_sized([70.0, 22.0], egui::Label::new(RichText::new(time).color(DIM)));
                            });
                        }
                    });
                }
            });
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                let shaders = stages.iter().find(|s| s.name.starts_with("Mac shaders")).and_then(|s| s.summary.split(" shaders ready").next().map(|n| n.rsplit(" of ").next().unwrap_or(n).to_string()));
                if let Some(n) = shaders {
                    badge(ui, Some(true), 22.0);
                    ui.label(RichText::new(format!("{n} shaders ready")).color(GREEN));
                }
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if !stages.is_empty() && !running {
                        let total: u64 = stages.iter().map(|s| s.secs).sum();
                        ui.label(RichText::new(format!("Total time: {}", mmss(total))).small().color(DIM));
                        match &result {
                            Some(Ok(_)) => {
                                ui.label(RichText::new("Build complete").color(GREEN));
                                badge(ui, Some(true), 22.0);
                            }
                            Some(Err(_)) => {
                                ui.label(RichText::new("Build failed").color(RED));
                                badge(ui, Some(false), 22.0);
                            }
                            None => {}
                        }
                    }
                });
            });
            if !log.is_empty() {
                egui::CollapsingHeader::new(RichText::new(format!("Log ({} lines)", log.len())).color(DIM)).show(ui, |ui| {
                    egui::ScrollArea::vertical().max_height(220.0).stick_to_bottom(true).show(ui, |ui| {
                        for l in &log {
                            ui.label(RichText::new(l).monospace().small().color(if l.contains("[RED]") { RED } else { DIM }));
                        }
                    });
                });
            }
        });
    }

    fn builds_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, checks: &Option<(Vec<Check>, Env)>, all_ok: bool, running: bool) {
        ui.label(RichText::new("Builds").size(32.0).strong());
        ui.label(RichText::new("Every Mac app the converter has built, and the engine each one uses.").size(17.0).color(DIM));
        ui.add_space(14.0);
        let ver = self.engine.lock().unwrap().clone();
        let env = checks.as_ref().map(|(_, e)| e.clone());
        let repo = env.as_ref().and_then(|e| e.repo.clone());
        card(ui, |ui| {
            title(ui, "Engine", "The nxnative checkout the converter builds with.");
            match (&repo, &ver) {
                (Some(r), Some(v)) => {
                    ui.label(RichText::new(v.label()).strong());
                    ui.label(RichText::new(format!("{} · branch {}", tilde(r), v.branch)).color(DIM));
                    ui.horizontal(|ui| {
                        if ui.add_enabled(!running, egui::Button::new("Check for updates…")).clicked() {
                            self.engine_action(r.clone(), false, ctx);
                        }
                        let msg = self.engine_msg.lock().unwrap().clone();
                        if msg.as_ref().is_some_and(|(ok, m)| *ok && m.contains("available"))
                            && ui.add_enabled(!running && !v.dirty, egui::Button::new("Update engine")).on_disabled_hover_text("the checkout has uncommitted changes").clicked()
                        {
                            self.engine_action(r.clone(), true, ctx);
                        }
                        if let Some((ok, m)) = msg {
                            ui.label(RichText::new(m).color(if ok { DIM } else { RED }));
                        }
                    });
                }
                (Some(r), None) => {
                    ui.label(format!("{} is not a git checkout, so builds cannot be versioned.", tilde(r)));
                }
                _ => {
                    ui.label(RichText::new("No repository yet: see Toolchain.").color(RED));
                }
            }
        });
        ui.add_space(14.0);
        card(ui, |ui| {
            title(ui, "Built apps", "Rebuild moves the old app to app-backups/ and builds it again on the current engine.");
            let mut builds = engine::builds();
            builds.retain(|b| b.app.exists());
            builds.sort_by(|a, b| b.built_at.cmp(&a.built_at));
            if builds.is_empty() {
                ui.label(RichText::new("Nothing built yet.").color(DIM));
            }
            for b in builds {
                ui.separator();
                let current = ver.as_ref().is_some_and(|v| v.commit == b.engine.commit && !v.dirty);
                ui.horizontal(|ui| {
                    badge(ui, Some(current), 22.0);
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let same_folder = self.s.game_dir.as_ref() == Some(&b.game_dir);
                        let label = ver.as_ref().map(|v| format!("Rebuild on {}", v.short())).unwrap_or_else(|| "Rebuild".into());
                        let ok = all_ok && !running && same_folder && self.s.keys.is_some();
                        if ui.add_enabled(ok, egui::Button::new(label)).on_disabled_hover_text("Choose this game's folder on the Convert page first").clicked() {
                            self.start(ctx, env.clone().unwrap(), Some(b.app.clone()));
                            self.page = Page::Convert;
                        }
                        if ui.button("Show in Finder").clicked() {
                            let _ = std::process::Command::new("/usr/bin/open").arg("-R").arg(&b.app).spawn();
                        }
                        ui.with_layout(Layout::top_down(Align::LEFT), |ui| {
                            ui.label(RichText::new(b.app.file_stem().unwrap().to_string_lossy()).strong());
                            ui.add(egui::Label::new(RichText::new(format!("Built {} · {} · {}", b.built_at, b.engine.short(), b.engine.subject)).small().color(DIM)).truncate());
                            ui.add(egui::Label::new(RichText::new(tilde(&b.app)).small().color(DIM)).truncate());
                        });
                    });
                });
            }
        });
    }

    fn toolchain_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, checks: &Option<(Vec<Check>, Env)>) {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Toolchain").size(32.0).strong());
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if self.checking {
                    ui.spinner();
                } else if ui.button("Check again").clicked() {
                    self.identities = prereq::signing_identities();
                    self.recheck(ctx);
                }
            });
        });
        ui.label(RichText::new("Everything the conversion needs, found the way the conversion script finds it.").size(17.0).color(DIM));
        ui.add_space(14.0);
        card(ui, |ui| {
            let Some((list, _)) = checks else {
                ui.spinner();
                return;
            };
            for (i, c) in list.iter().enumerate() {
                if i > 0 {
                    ui.separator();
                }
                ui.horizontal(|ui| {
                    badge(ui, if c.ok { Some(true) } else if c.optional { None } else { Some(false) }, 22.0);
                    ui.vertical(|ui| {
                        ui.label(RichText::new(format!("{}{}", c.name, if c.optional { "  (optional)" } else { "" })).strong());
                        ui.label(RichText::new(c.why).small().color(DIM));
                    });
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if let Some(fix) = c.fix.as_ref().filter(|_| !c.ok) {
                            if ui.button("Fix in Terminal").on_hover_text(fix).clicked() {
                                prereq::run_in_terminal(fix);
                            }
                        }
                        ui.add(egui::Label::new(RichText::new(&c.detail).small().color(DIM)).truncate());
                    });
                });
            }
        });
    }

    fn settings_page(&mut self, ui: &mut egui::Ui, ctx: &egui::Context, checks: &Option<(Vec<Check>, Env)>) {
        ui.label(RichText::new("Settings").size(32.0).strong());
        ui.label(RichText::new("Where the engine and Python are, and how apps are signed.").size(17.0).color(DIM));
        ui.add_space(14.0);
        card(ui, |ui| {
            let repo = self.s.repo.clone().or_else(|| checks.as_ref().and_then(|(_, e)| e.repo.clone()));
            if path_row(ui, "Engine checkout", 130.0, &repo.as_deref().map(tilde).unwrap_or_default(), true) {
                if let Some(d) = rfd::FileDialog::new().pick_folder() {
                    self.s.repo = Some(d);
                    self.s.save();
                    self.recheck(ctx);
                }
            }
            let py = self.s.python.clone().or_else(|| checks.as_ref().and_then(|(_, e)| e.python.clone()));
            if path_row(ui, "Python", 130.0, &py.as_deref().map(tilde).unwrap_or_default(), true) {
                if let Some(f) = rfd::FileDialog::new().pick_file() {
                    self.s.python = Some(f);
                    self.s.save();
                    self.recheck(ctx);
                }
            }
            if self.s.python.is_some() && ui.button("Find Python automatically").clicked() {
                self.s.python = None;
                self.s.save();
                self.recheck(ctx);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.add_sized([130.0, 34.0], egui::Label::new("Sign apps with"));
                let cur = self.s.sign_identity.clone().unwrap_or_else(|| "Ad-hoc (this Mac only)".into());
                egui::ComboBox::from_id_salt("sign").width(ui.available_width() - 10.0).selected_text(cur).show_ui(ui, |ui| {
                    let mut changed = ui.selectable_value(&mut self.s.sign_identity, None, "Ad-hoc (this Mac only)").changed();
                    for id in &self.identities {
                        changed |= ui.selectable_value(&mut self.s.sign_identity, Some(id.clone()), id).changed();
                    }
                    if changed {
                        self.s.save();
                    }
                });
            });
        });
    }
}

/// A left-aligned table cell of a fixed width.
fn cell(ui: &mut egui::Ui, w: f32, t: RichText) {
    ui.allocate_ui_with_layout(Vec2::new(w, 26.0), Layout::left_to_right(Align::Center), |ui| {
        ui.set_width(w);
        ui.add(egui::Label::new(t).truncate());
    });
}

/// "Mario vs. Donkey Kong [0100B99019412800][v65536].nsp" → "Mario vs. Donkey Kong update.nsp" style: the tags go to the Type column.
fn short_name(n: &str) -> String {
    let ext = n.rsplit('.').next().unwrap_or("");
    let base = n.split(" [").next().unwrap_or(n).trim();
    let is_update = n.contains("800]");
    format!("{base}{}.{ext}", if is_update { " update" } else { "" })
}
