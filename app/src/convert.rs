// Runs scripts/build_ipa_from_nsp.py --platform mac-app --progress json and follows its events
// (stage, step, progress, stage_end, say: docs/development.md), then checks the app's signature.
use crate::prereq::Env;
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

#[derive(Default, Clone)]
pub struct Stage {
    pub k: u64,
    pub n: u64,
    pub name: String,
    pub step: String,
    pub frac: Option<f32>,
    pub detail: String,
}

#[derive(Clone)]
pub struct StageDone {
    pub k: u64,
    pub n: u64,
    pub name: String,
    pub ok: bool,
    pub secs: u64,
    pub summary: String,
}

impl StageDone {
    pub fn line(&self) -> String {
        format!("[{}/{}] {} ({}:{:02}){}", self.k, self.n, self.name, self.secs / 60, self.secs % 60, if self.summary.is_empty() { String::new() } else { format!(": {}", self.summary) })
    }
    pub fn reused(&self) -> bool {
        self.summary.contains("reused")
    }
}

#[derive(Default)]
pub struct State {
    pub running: bool,
    pub pid: Option<u32>,
    pub stage: Stage,
    pub done_stages: Vec<StageDone>,
    pub log: Vec<String>,
    pub app: Option<PathBuf>,
    pub backup: Option<PathBuf>,
    pub result: Option<Result<String, String>>,
}

pub type Shared = Arc<Mutex<State>>;

pub struct Job {
    pub game_dir: PathBuf,
    pub keys: PathBuf,
    pub sign: Option<String>,
    pub env: Env,
    /// Rebuild this app in place: it is moved to app-backups/ first and put back if the build fails.
    pub rebuild: Option<PathBuf>,
    /// where the app goes (-o); None = <game name>.app in the game folder
    pub out: Option<PathBuf>,
}

pub fn start(job: Job, st: Shared, repaint: impl Fn() + Send + 'static) {
    {
        let mut s = st.lock().unwrap();
        *s = State { running: true, ..Default::default() };
    }
    std::thread::spawn(move || {
        let r = run(&job, &st, &repaint);
        let mut s = st.lock().unwrap();
        s.running = false;
        s.pid = None;
        s.result = Some(r);
        drop(s);
        repaint();
    });
}

/// Ask the script to stop as Ctrl-C would (it ends the stage and exits with 130).
pub fn cancel(st: &Shared) {
    if let Some(pid) = st.lock().unwrap().pid {
        let _ = Command::new("/bin/kill").args(["-INT", &pid.to_string()]).status();
    }
}

/// One build per game folder at a time, across this app's windows and command-line runs: two builds of the
/// same folder share <id>_build/ and the output app, and clobber each other.
struct Lock(PathBuf);

impl Lock {
    fn take(dir: &Path) -> Result<Lock, String> {
        let p = dir.join(".nxnative-converter.lock");
        if let Ok(pid) = std::fs::read_to_string(&p) {
            let alive = Command::new("/bin/kill").args(["-0", pid.trim()]).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
            if alive {
                return Err(format!("another build of this folder is running (process {}); wait for it to finish", pid.trim()));
            }
        }
        std::fs::write(&p, std::process::id().to_string()).map_err(|e| format!("cannot write {}: {e}", p.display()))?;
        Ok(Lock(p))
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn run(job: &Job, st: &Shared, repaint: &dyn Fn()) -> Result<String, String> {
    let _lock = Lock::take(&job.game_dir)?;
    let repo = job.env.repo.as_ref().ok_or("no nxnative repository")?;
    let engine = crate::engine::current(repo).ok_or("cannot read the engine's git commit")?;
    let mut backup = None;
    if let Some(app) = &job.rebuild {
        let old = crate::engine::builds().into_iter().find(|b| &b.app == app).map(|b| b.engine);
        let b = crate::engine::back_up(app, old.as_ref())?;
        st.lock().unwrap().log.push(format!("old app moved to {}", b.display()));
        st.lock().unwrap().backup = Some(b.clone());
        backup = Some(b);
    }
    let r = build(job, repo, st, repaint);
    match (&r, &backup, &job.rebuild) {
        (Ok(_), _, _) => {
            if let Some(app) = st.lock().unwrap().app.clone() {
                crate::engine::record(crate::engine::Build { app, game_dir: job.game_dir.clone(), engine, repo: repo.clone(), built_at: crate::engine::now() });
            }
        }
        (Err(_), Some(b), Some(app)) => {
            // keep a working game: put the old app back unless the failed build left something in its place
            if !app.exists() && std::fs::rename(b, app).is_ok() {
                st.lock().unwrap().log.push(format!("build failed: the old app is back at {}", app.display()));
                st.lock().unwrap().backup = None;
            }
        }
        _ => {}
    }
    r
}

fn build(job: &Job, repo: &Path, st: &Shared, repaint: &dyn Fn()) -> Result<String, String> {
    let py = job.env.python.as_ref().ok_or("no Python with the script's modules")?;
    let mut cmd = Command::new(py);
    cmd.arg("-u")
        .arg(repo.join(crate::prereq::SCRIPT))
        .arg(&job.game_dir)
        .arg("-k")
        .arg(&job.keys)
        .args(["--platform", "mac-app", "--progress", "json"])
        .current_dir(repo)
        .env("PATH", &job.env.path)
        .env("PYTHONUNBUFFERED", "1")
        .envs(job.env.dotnet_root.iter().filter(|_| std::env::var_os("DOTNET_ROOT").is_none()).map(|d| ("DOTNET_ROOT", d)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(id) = &job.sign {
        cmd.args(["--mac-sign", id]);
    }
    if let Some(app) = job.rebuild.as_ref().or(job.out.as_ref()) {
        cmd.arg("-o").arg(app);
    }
    let mut child = cmd.spawn().map_err(|e| format!("cannot start {}: {e}", py.display()))?;
    st.lock().unwrap().pid = Some(child.id());

    let stderr = child.stderr.take().unwrap();
    let st2 = st.clone();
    let err_thread = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            st2.lock().unwrap().log.push(line);
        }
    });
    for line in BufReader::new(child.stdout.take().unwrap()).lines().map_while(Result::ok) {
        event(&line, &mut st.lock().unwrap());
        repaint();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let _ = err_thread.join();
    match status.code() {
        Some(0) => {}
        Some(130) => return Err("stopped".into()),
        c => {
            let s = st.lock().unwrap();
            let last = s.log.iter().rev().find(|l| l.contains("[RED]")).cloned().unwrap_or_else(|| format!("the script exited with {c:?}"));
            return Err(last);
        }
    }
    let app = st.lock().unwrap().app.clone().ok_or("the script finished but named no app")?;
    verify(&app)
}

fn event(line: &str, s: &mut State) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        s.log.push(line.to_string());
        return;
    };
    let str_of = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    match v.get("ev").and_then(Value::as_str) {
        Some("stage") => {
            s.stage = Stage {
                k: v["k"].as_u64().unwrap_or(0),
                n: v["n"].as_u64().unwrap_or(0),
                name: str_of("name"),
                step: str_of("step"),
                ..Default::default()
            };
        }
        Some("step") => s.stage.step = str_of("step"),
        Some("progress") => {
            s.stage.step = str_of("step");
            s.stage.frac = v["frac"].as_f64().map(|f| f as f32);
            let mut d = String::new();
            if let (Some(done), Some(total)) = (v["done"].as_f64(), v["total"].as_f64()) {
                let unit = str_of("unit");
                let est = if v["est"].as_bool() == Some(true) { "~" } else { "" };
                d = if unit == "B" { format!("{:.1}/{est}{:.1} GB", done / 1e9, total / 1e9) } else { format!("{done:.0}/{est}{total:.0} {unit}") };
            }
            if let Some(eta) = v["eta"].as_f64() {
                d += &format!(" · ETA {}:{:02}", eta as u64 / 60, eta as u64 % 60);
            }
            s.stage.detail = d;
        }
        Some("stage_end") => {
            let ok = v["ok"].as_bool().unwrap_or(true);
            let el = v["elapsed"].as_f64().unwrap_or(0.0) as u64;
            let summary = str_of("summary");
            let d = StageDone { k: s.stage.k, n: s.stage.n, name: s.stage.name.clone(), ok, secs: el, summary };
            s.done_stages.push(d);
            s.stage.frac = Some(1.0);
        }
        Some("say") => {
            let msg = str_of("msg");
            // "[hh:mm:ss] done: <path>.app (… GB …)"
            if let Some(i) = msg.find("done: ") {
                let rest = &msg[i + 6..];
                if let Some(j) = rest.find(".app") {
                    s.app = Some(PathBuf::from(&rest[..j + 4]));
                }
            }
            s.log.extend(msg.lines().map(String::from));
        }
        _ => s.log.push(line.to_string()),
    }
}

/// The app must be a bundle with an executable launcher and a valid signature.
pub fn verify(app: &Path) -> Result<String, String> {
    use std::os::unix::fs::PermissionsExt;
    let exe = app.join("Contents/MacOS/nxnative");
    let mode = exe.metadata().map_err(|_| format!("{} has no launcher", app.display()))?.permissions().mode();
    if mode & 0o111 == 0 {
        return Err(format!("{} is not executable", exe.display()));
    }
    let v = Command::new("/usr/bin/codesign").args(["--verify", "--deep", "--strict"]).arg(app).output().map_err(|e| e.to_string())?;
    if !v.status.success() {
        return Err(format!("signature check failed: {}", String::from_utf8_lossy(&v.stderr).trim()));
    }
    let d = Command::new("/usr/bin/codesign").arg("-dv").arg(app).output().map_err(|e| e.to_string())?;
    let info = String::from_utf8_lossy(&d.stderr);
    let signer = info
        .lines()
        .find_map(|l| l.strip_prefix("Authority="))
        .map(String::from)
        .unwrap_or_else(|| if info.contains("Signature=adhoc") { "ad-hoc".into() } else { "unknown".into() });
    Ok(format!("{} is signed ({signer}) and the signature verifies", app.display()))
}
