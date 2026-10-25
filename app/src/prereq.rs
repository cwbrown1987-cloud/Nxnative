// What scripts/build_ipa_from_nsp.py --platform mac-app needs, checked the way the script checks it
// (check_prereqs, its TOOL_PATHS before PATH), so a tick here means the script will find the same tool.
use crate::settings::{support_dir, Settings};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const SCRIPT: &str = "scripts/build_ipa_from_nsp.py";
pub const FORK_URL: &str = "https://github.com/gnosticgeek/nxnative.git";

#[derive(Clone)]
pub struct Check {
    pub name: &'static str,
    pub why: &'static str,
    pub ok: bool,
    pub optional: bool,
    pub detail: String,
    /// A shell command that installs or fixes it, run in Terminal on request.
    pub fix: Option<String>,
}

/// Everything resolved while checking, which the conversion then uses.
#[derive(Clone, Default)]
pub struct Env {
    pub repo: Option<PathBuf>,
    pub python: Option<PathBuf>,
    pub path: String,
    /// the folder of the dotnet the script finds: the shader translator's launcher (an apphost) finds the
    /// runtime only through DOTNET_ROOT or /usr/local/share/dotnet, not through PATH
    pub dotnet_root: Option<PathBuf>,
}

pub fn is_repo(p: &Path) -> bool {
    p.join(SCRIPT).is_file() && p.join("dm/tools/nx_extract/Program.cs").is_file()
}

/// The repository: the setting, else the checkout this app sits in, else a few usual places.
pub fn find_repo(s: &Settings) -> Option<PathBuf> {
    if let Some(r) = s.repo.as_ref().filter(|r| is_repo(r)) {
        return Some(r.clone());
    }
    let mut cands: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        cands.extend(exe.ancestors().map(Path::to_path_buf));
    }
    let home = dirs::home_dir().unwrap_or_default();
    for d in ["Developer/nxnative", "nxnative", "src/nxnative", "Documents/nxnative", "Projects/nxnative", "code/nxnative"] {
        cands.push(home.join(d));
    }
    cands.push(support_dir().join("nxnative"));
    cands.into_iter().find(|c| is_repo(c))
}

/// The script's TOOL_PATHS list, read from its source (it may be edited locally), else upstream's.
fn tool_paths(repo: Option<&Path>) -> Vec<String> {
    let home = dirs::home_dir().unwrap_or_default().to_string_lossy().to_string();
    let default = vec!["/opt/homebrew/bin".into(), "/usr/local/bin".into(), "/usr/local/share/dotnet".into(), format!("{home}/.dotnet")];
    let Some(src) = repo.and_then(|r| std::fs::read_to_string(r.join(SCRIPT)).ok()) else { return default };
    let Some(line) = src.lines().find(|l| l.starts_with("TOOL_PATHS = [")) else { return default };
    let body = &line["TOOL_PATHS = [".len()..line.find(']').unwrap_or(line.len())];
    let mut out = Vec::new();
    for part in body.split(',') {
        let part = part.trim();
        let q: Vec<&str> = part.split('\'').collect();
        if q.len() >= 3 {
            let s = q[1];
            out.push(if part.contains("expanduser") { s.replacen('~', &home, 1) } else { s.to_string() });
        }
    }
    if out.is_empty() { default } else { out }
}

/// PATH as the script will see it: its TOOL_PATHS first, then ours (a Finder-launched app has a bare PATH).
pub fn script_path(repo: Option<&Path>) -> String {
    let mut parts = tool_paths(repo);
    let inherited = std::env::var("PATH").unwrap_or_default();
    parts.extend(inherited.split(':').filter(|s| !s.is_empty()).map(String::from));
    parts.extend(["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map(String::from));
    let mut seen = std::collections::HashSet::new();
    parts.retain(|p| seen.insert(p.clone()));
    parts.join(":")
}

pub fn which(tool: &str, path: &str) -> Option<PathBuf> {
    path.split(':').map(|d| Path::new(d).join(tool)).find(|p| {
        use std::os::unix::fs::PermissionsExt;
        p.is_file() && p.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    })
}

fn run(cmd: &Path, args: &[&str], path: &str) -> Option<(bool, String)> {
    let o = Command::new(cmd).args(args).env("PATH", path).output().ok()?;
    let text = if o.stdout.is_empty() { &o.stderr } else { &o.stdout };
    Some((o.status.success(), String::from_utf8_lossy(text).trim().to_string()))
}

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").to_string()
}

/// Python interpreters to try: the setting, this app's venv, the checkout's .venv, then every python3 on PATH.
fn python_candidates(s: &Settings, repo: Option<&Path>, path: &str) -> Vec<PathBuf> {
    let mut c: Vec<PathBuf> = Vec::new();
    if let Some(p) = &s.python {
        c.push(p.clone());
    }
    c.push(support_dir().join("venv/bin/python3"));
    if let Some(r) = repo {
        c.push(r.join(".venv/bin/python3"));
    }
    for d in path.split(':') {
        c.push(Path::new(d).join("python3"));
    }
    let mut seen = std::collections::HashSet::new();
    c.retain(|p| p.is_file() && seen.insert(p.canonicalize().unwrap_or(p.clone())));
    c
}

/// (missing modules, version) for one interpreter.
fn python_missing(py: &Path, path: &str) -> Option<(Vec<String>, String)> {
    let probe = "import importlib.util as u, sys\n\
        def has(m):\n    try: __import__(m); return True\n    except ImportError: return False\n\
        miss=[m for m in ('lz4.block','capstone','fontTools') if not has(m)]\n\
        if not (has('compression.zstd') or has('backports.zstd')): miss.append('backports.zstd')\n\
        print('%d.%d.%d' % sys.version_info[:3]); print(','.join(miss))";
    let (ok, out) = run(py, &["-I", "-c", probe], path)?;
    if !ok {
        return None;
    }
    let mut l = out.lines();
    let ver = l.next().unwrap_or("").to_string();
    let miss = l.next().unwrap_or("").split(',').filter(|s| !s.is_empty()).map(String::from).collect();
    Some((miss, ver))
}

pub fn check_all(s: &Settings) -> (Vec<Check>, Env) {
    let mut v = Vec::new();
    let repo = find_repo(s);
    let path = script_path(repo.as_deref());
    let mut push = |name, why, ok, optional, detail: String, fix: Option<String>| v.push(Check { name, why, ok, optional, detail, fix });

    let arm = std::env::consts::ARCH == "aarch64";
    push("Apple silicon Mac", "the game's own arm64 code runs natively", arm, false, std::env::consts::ARCH.into(), None);

    let clone_to = support_dir().join("nxnative");
    push(
        "nxnative repository",
        "the conversion script, rewriter, host and shader tools",
        repo.is_some(),
        false,
        repo.as_ref().map(|r| r.display().to_string()).unwrap_or_else(|| "not found: choose its folder in Settings, or clone it".into()),
        Some(format!("git clone {FORK_URL} {}", sh(&clone_to))),
    );
    let xb = which("xcodebuild", &path).and_then(|p| run(&p, &["-version"], &path));
    let xok = xb.as_ref().is_some_and(|(ok, _)| *ok);
    push(
        "Xcode",
        "the Metal compiler, clang and the macOS SDK",
        xok,
        false,
        xb.map(|(_, o)| first_line(&o)).unwrap_or_else(|| "xcodebuild not found".into()),
        Some("open 'macappstore://apps.apple.com/app/id497799835'".into()),
    );
    let metal = run(Path::new("/usr/bin/xcrun"), &["-sdk", "macosx", "metal", "--version"], &path);
    push(
        "Metal toolchain",
        "compiles the Mac shader libraries",
        metal.as_ref().is_some_and(|(ok, _)| *ok),
        false,
        metal.map(|(_, o)| first_line(&o)).unwrap_or_else(|| "xcrun not found".into()),
        Some("xcodebuild -downloadComponent MetalToolchain".into()),
    );
    for (tool, why) in [("make", "builds the Mac host"), ("clang", "compiles the host and the app launcher")] {
        let p = which(tool, &path);
        push(tool_label(tool), why, p.is_some(), false, p.map(|p| p.display().to_string()).unwrap_or_else(|| "not found".into()), Some("xcode-select --install".into()));
    }

    // dotnet: the first one on the script's PATH must have SDK 10 (nx_extract targets net10.0)
    let dn = which("dotnet", &path);
    let dotnet_root = dn.as_ref().and_then(|d| d.canonicalize().ok()).and_then(|d| d.parent().map(Path::to_path_buf));
    let sdks = dn.as_ref().and_then(|d| run(d, &["--list-sdks"], &path)).map(|(_, o)| o).unwrap_or_default();
    let has10 = sdks.lines().any(|l| l.starts_with("10."));
    let versions: Vec<&str> = sdks.lines().filter_map(|l| l.split_whitespace().next()).collect();
    push(
        ".NET SDK 10",
        "builds nx_extract, which reads the NSPs",
        has10,
        false,
        match &dn {
            None => "dotnet not found".into(),
            Some(d) if has10 => format!("{} ({})", d.display(), versions.join(", ")),
            Some(d) => format!("{} has SDK {} only; the script uses the first dotnet on its PATH", d.display(), if versions.is_empty() { "none".into() } else { versions.join(", ") }),
        },
        Some(match &dn {
            Some(d) => format!(
                "curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir {}",
                sh(d.canonicalize().unwrap_or(d.clone()).parent().unwrap())
            ),
            None => "brew install --cask dotnet-sdk".into(),
        }),
    );

    // the translator's launcher must start: it finds .NET only through DOTNET_ROOT (which the conversion sets)
    if let Some(r) = &repo {
        let x = r.join("dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate");
        let mut c = Command::new(&x);
        c.arg("--source-sha").env("PATH", &path);
        if let Some(d) = &dotnet_root {
            c.env("DOTNET_ROOT", d);
        }
        let out = c.output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).filter(|s| !s.is_empty());
        push(
            "Shader translator",
            "turns the game's Maxwell shaders into SPIR-V",
            out.is_some(),
            false,
            match &out {
                Some(sha) => format!("{} (source {sha})", x.display()),
                None if !x.exists() => format!("{} is missing", x.display()),
                None => "does not start: it needs the .NET 10 runtime".into(),
            },
            None,
        );
    }

    for (tool, why, pkg) in [("zstd", "decompresses game data", "zstd"), ("spirv-cross", "SPIR-V to Metal Shading Language", "spirv-cross")] {
        let p = which(tool, &path);
        push(tool_label(tool), why, p.is_some(), false, p.map(|p| p.display().to_string()).unwrap_or_else(|| "not found".into()), Some(format!("brew install {pkg}")));
    }

    let mut python = None;
    let cands = python_candidates(s, repo.as_deref(), &path);
    let mut best: Option<(PathBuf, Vec<String>, String)> = None;
    for c in &cands {
        if let Some((miss, ver)) = python_missing(c, &path) {
            if miss.is_empty() {
                best = Some((c.clone(), miss, ver));
                break;
            }
            if best.is_none() {
                best = Some((c.clone(), miss, ver));
            }
        }
    }
    let venv = support_dir().join("venv");
    let venv_fix = format!(
        "python3 -m venv {v} && {v}/bin/pip install lz4 capstone fonttools nsz \"backports.zstd; python_version < '3.14'\"",
        v = sh(&venv)
    );
    match &best {
        Some((p, miss, ver)) if miss.is_empty() => {
            python = Some(p.clone());
            push("Python modules", "lz4, capstone, fontTools, zstd for the script", true, false, format!("{} (Python {ver})", p.display()), Some(venv_fix.clone()));
        }
        Some((p, miss, ver)) => push(
            "Python modules",
            "lz4, capstone, fontTools, zstd for the script",
            false,
            false,
            format!("{} (Python {ver}) lacks {}", p.display(), miss.join(", ")),
            Some(venv_fix.clone()),
        ),
        None => push("Python modules", "lz4, capstone, fontTools, zstd for the script", false, false, "no python3 found".into(), Some(venv_fix.clone())),
    }

    let pack: Vec<&str> = ["codesign", "sips", "iconutil"].into_iter().filter(|t| which(t, &path).is_none()).collect();
    push("App packing tools", "codesign, sips, iconutil (part of macOS)", pack.is_empty(), false, if pack.is_empty() { "codesign, sips, iconutil".into() } else { format!("missing: {}", pack.join(", ")) }, None);

    // optional: only some games or file types need them
    let gl = which("glslangValidator", &path);
    push("glslang", "only OpenGL games (e.g. Fire Emblem: Three Houses)", gl.is_some(), true, gl.map(|p| p.display().to_string()).unwrap_or_else(|| "not found".into()), Some("brew install glslang".into()));
    let nsz = python.as_ref().and_then(|p| run(p, &["-I", "-c", "import nsz"], &path)).is_some_and(|(ok, _)| ok);
    push("nsz", "only compressed .nsz / .xcz files", nsz, true, if nsz { "installed".into() } else { "not installed in that Python".into() }, python.as_ref().map(|p| format!("{} -m pip install nsz", sh(p))));

    (v, Env { repo, python, path, dotnet_root })
}

fn tool_label(t: &str) -> &'static str {
    match t {
        "make" => "make",
        "clang" => "clang",
        "zstd" => "zstd",
        "spirv-cross" => "spirv-cross",
        _ => "tool",
    }
}

/// Single-quote a path for a shell command.
pub fn sh(p: &Path) -> String {
    format!("'{}'", p.display().to_string().replace('\'', "'\\''"))
}

/// Run a command in a new Terminal window, so the user sees it and can type a password.
pub fn run_in_terminal(cmd: &str) {
    let script = format!("tell application \"Terminal\"\nactivate\ndo script \"{}\"\nend tell", cmd.replace('\\', "\\\\").replace('"', "\\\""));
    let _ = Command::new("/usr/bin/osascript").arg("-e").arg(script).spawn();
}

/// Code signing identities from the keychain (name only), for the signing menu.
pub fn signing_identities() -> Vec<String> {
    let Ok(o) = Command::new("/usr/bin/security").args(["find-identity", "-v", "-p", "codesigning"]).output() else { return vec![] };
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .filter_map(|l| {
            let a = l.find('"')?;
            let b = l.rfind('"')?;
            (b > a).then(|| l[a + 1..b].to_string())
        })
        .collect()
}
