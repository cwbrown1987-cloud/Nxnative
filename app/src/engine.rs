// The engine is the nxnative checkout the script runs from: its commit is the version a game app is built
// with. Each successful build is recorded in builds.json (beside settings.json) with that commit, since the
// app bundle itself does not carry one; an app built before that shows as "unknown".
use crate::settings::support_dir;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Version {
    pub commit: String,
    pub subject: String,
    pub date: String,
    pub branch: String,
    /// uncommitted changes in the checkout when it was read
    pub dirty: bool,
}

impl Version {
    pub fn short(&self) -> &str {
        &self.commit[..self.commit.len().min(7)]
    }
    pub fn label(&self) -> String {
        format!("{}{} · {} · {}", self.short(), if self.dirty { "+changes" } else { "" }, self.subject, self.date)
    }
}

fn git(repo: &Path, args: &[&str]) -> Result<String, String> {
    let o = Command::new("git").arg("-C").arg(repo).args(args).env("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").output().map_err(|e| e.to_string())?;
    if o.status.success() {
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&o.stderr).trim().to_string())
    }
}

pub fn current(repo: &Path) -> Option<Version> {
    let log = git(repo, &["log", "-1", "--format=%H%x1f%s%x1f%cs"]).ok()?;
    let mut p = log.split('\x1f');
    let (commit, subject, date) = (p.next()?.to_string(), p.next()?.to_string(), p.next()?.to_string());
    let branch = git(repo, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
    // changes to tracked files only: untracked files (a new tool, build output) do not change what is built
    let dirty = !git(repo, &["status", "--porcelain", "--untracked-files=no"]).unwrap_or_default().is_empty();
    Some(Version { commit, subject, date, branch, dirty })
}

/// After a fetch: (commits on the upstream branch that HEAD lacks, their newest subject).
pub fn check_updates(repo: &Path) -> Result<(usize, String), String> {
    git(repo, &["fetch", "--quiet", "origin"])?;
    let up = git(repo, &["rev-parse", "--abbrev-ref", "@{upstream}"]).map_err(|_| "this branch has no upstream branch to update from".to_string())?;
    let n: usize = git(repo, &["rev-list", "--count", &format!("HEAD..{up}")])?.parse().unwrap_or(0);
    let subject = if n > 0 { git(repo, &["log", "-1", "--format=%s", &up])? } else { String::new() };
    Ok((n, subject))
}

/// Fast-forward to the upstream branch; refuses when that would need a merge.
pub fn update(repo: &Path) -> Result<String, String> {
    git(repo, &["pull", "--ff-only", "--quiet"])?;
    Ok(current(repo).map(|v| v.label()).unwrap_or_default())
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Build {
    pub app: PathBuf,
    pub game_dir: PathBuf,
    pub engine: Version,
    pub repo: PathBuf,
    pub built_at: String,
}

fn builds_file() -> PathBuf {
    support_dir().join("builds.json")
}

pub fn builds() -> Vec<Build> {
    std::fs::read(builds_file()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn record(b: Build) {
    let mut all: Vec<Build> = builds().into_iter().filter(|x| x.app != b.app).collect();
    all.push(b);
    let _ = std::fs::create_dir_all(support_dir());
    if let Ok(j) = serde_json::to_vec_pretty(&all) {
        let _ = std::fs::write(builds_file(), j);
    }
}

pub fn now() -> String {
    Command::new("/bin/date").arg("+%Y-%m-%d %H:%M").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

/// The game apps in a folder (top level), each with the engine it was recorded as built with.
pub fn apps_in(dir: &Path) -> Vec<(PathBuf, Option<Build>)> {
    let known = builds();
    let mut v: Vec<(PathBuf, Option<Build>)> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|e| e == "app") && p.join("Contents/MacOS/dmhost").is_file())
                .map(|p| {
                    let b = known.iter().find(|b| b.app == p).cloned();
                    (p, b)
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}

/// Move an app aside before rebuilding it: <folder>/app-backups/<name> (<engine or "old">, <time>).app.
/// A rename on the same volume, so it is instant and takes no space.
pub fn back_up(app: &Path, engine: Option<&Version>) -> Result<PathBuf, String> {
    let dir = app.parent().unwrap().join("app-backups");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stem = app.file_stem().unwrap().to_string_lossy();
    let tag = engine.map(|v| v.short().to_string()).unwrap_or_else(|| "old engine".into());
    let stamp = now().replace([':', ' '], "-");
    let dst = dir.join(format!("{stem} ({tag}, {stamp}).app"));
    std::fs::rename(app, &dst).map_err(|e| format!("cannot move {} aside: {e}", app.display()))?;
    Ok(dst)
}
