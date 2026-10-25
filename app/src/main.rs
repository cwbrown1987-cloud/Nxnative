// NxNative Converter: a window over scripts/build_ipa_from_nsp.py --platform mac-app.
// 1. lists what the script needs, ticked or crossed; 2. checks a game folder against prod.keys;
// 3. converts the folder to a signed Mac app. The same steps run headless for testing:
//   nxnative-converter --check | --validate <folder> <prod.keys> | --convert <folder> <prod.keys> [--sign <identity>] | --verify <app>
//   | --engine [<folder>] (the engine's commit, and which apps in the folder were built on it) | --rebuild <app> <prod.keys> [--sign <identity>]
mod convert;
mod engine;
mod gameinfo;
mod gui;
mod keys;
mod nsp;
mod prereq;
mod settings;

use std::path::PathBuf;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("--check") => cli_check(),
        Some("--validate") if args.len() >= 3 => cli_validate(&args[1], &args[2]),
        Some("--convert") if args.len() >= 3 => cli_convert(&args[1], &args[2], sign_arg(&args), None),
        Some("--rebuild") if args.len() >= 3 => {
            let app = PathBuf::from(&args[1]);
            let dir = app.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
            cli_convert(&dir, &args[2], sign_arg(&args), Some(app))
        }
        Some("--engine") => cli_engine(args.get(1)),
        Some("--verify") if args.len() >= 2 => match convert::verify(&PathBuf::from(&args[1])) {
            Ok(m) => {
                println!("✓ {m}");
                0
            }
            Err(e) => {
                println!("✗ {e}");
                1
            }
        },
        Some(a) if a.starts_with("--") => {
            eprintln!("usage: nxnative-converter [--check | --validate <folder> <prod.keys> | --convert <folder> <prod.keys> [--sign <identity>] | --verify <app> | --engine [<folder>] | --rebuild <app> <prod.keys> [--sign <identity>]]");
            2
        }
        _ => {
            gui::run();
            0
        }
    };
    std::process::exit(code);
}

fn sign_arg(args: &[String]) -> Option<String> {
    args.iter().position(|a| a == "--sign").and_then(|i| args.get(i + 1)).cloned()
}

fn cli_engine(dir: Option<&String>) -> i32 {
    let (_, env) = prereq::check_all(&settings::Settings::load());
    let Some(repo) = env.repo else {
        println!("✗ no nxnative repository");
        return 1;
    };
    let Some(v) = engine::current(&repo) else {
        println!("✗ {} is not a git checkout", repo.display());
        return 1;
    };
    println!("engine {} ({}): {}", repo.display(), v.branch, v.label());
    for (app, b) in dir.map(|d| engine::apps_in(std::path::Path::new(d))).unwrap_or_default() {
        match b {
            Some(b) if b.engine.commit == v.commit && !b.engine.dirty && !v.dirty => println!("✓ {}: {} (current)", app.display(), b.engine.label()),
            Some(b) => println!("✗ {}: {} (older engine)", app.display(), b.engine.label()),
            None => println!("✗ {}: unknown engine (built before the converter tracked engines)", app.display()),
        }
    }
    0
}

fn mark(ok: bool, optional: bool) -> &'static str {
    if ok { "✓" } else if optional { "–" } else { "✗" }
}

fn cli_check() -> i32 {
    let (checks, _) = prereq::check_all(&settings::Settings::load());
    for c in &checks {
        println!("{} {:<22} {}{}", mark(c.ok, c.optional), c.name, c.detail, if c.optional { "  (optional)" } else { "" });
        if !c.ok {
            if let Some(f) = &c.fix {
                println!("      fix: {f}");
            }
        }
    }
    if checks.iter().all(|c| c.ok || c.optional) { 0 } else { 1 }
}

fn cli_validate(dir: &str, keys: &str) -> i32 {
    let v = nsp::validate(&PathBuf::from(dir), &PathBuf::from(keys));
    for l in &v.summary {
        println!("{} {}", mark(l.ok, false), l.text);
    }
    for f in &v.files {
        println!("{} {} ({})", mark(f.ok, false), f.name, f.role);
        for l in &f.lines {
            println!("    {} {}", mark(l.ok, false), l.text);
        }
    }
    if v.ok { 0 } else { 1 }
}

fn cli_convert(dir: &str, keys: &str, sign: Option<String>, rebuild: Option<PathBuf>) -> i32 {
    let s = settings::Settings::load();
    let (checks, env) = prereq::check_all(&s);
    let missing: Vec<&str> = checks.iter().filter(|c| !c.ok && !c.optional).map(|c| c.name).collect();
    if !missing.is_empty() {
        println!("✗ missing: {}", missing.join(", "));
        return 1;
    }
    if cli_validate(dir, keys) != 0 {
        return 1;
    }
    let st = convert::Shared::default();
    let job = convert::Job { game_dir: PathBuf::from(dir), keys: PathBuf::from(keys), sign, env, rebuild, out: None };
    let shown = std::sync::Arc::new(std::sync::Mutex::new((0usize, String::new())));
    let (st2, shown2) = (st.clone(), shown.clone());
    convert::start(job, st.clone(), move || {
        let s = st2.lock().unwrap();
        let mut sh = shown2.lock().unwrap();
        for l in &s.done_stages[sh.0..] {
            println!("{} {}", mark(l.ok, false), l.line());
        }
        sh.0 = s.done_stages.len();
        let now = format!("[{}/{}] {} · {}", s.stage.k, s.stage.n, s.stage.name, s.stage.step);
        if s.running && now != sh.1 {
            println!("  … {now}");
            sh.1 = now;
        }
    });
    loop {
        std::thread::sleep(std::time::Duration::from_millis(200));
        let s = st.lock().unwrap();
        if let Some(r) = &s.result {
            return match r {
                Ok(m) => {
                    println!("✓ {m}");
                    0
                }
                Err(e) => {
                    println!("✗ {e}");
                    1
                }
            };
        }
    }
}
