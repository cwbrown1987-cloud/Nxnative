// Checks a game folder against prod.keys without extracting anything: for each NCA in each NSP / XCI
// (or NSZ / XCZ) it decrypts the header with header_key, works out which keys the content needs from its
// key generation and rights ID, decrypts the title key (from the NSP's ticket) or the key area, and then
// decrypts the first bytes of an encrypted section to check that they read as a file system. A few KB per NCA.
// Key values are never shown; reports name keys only.
use crate::keys::Keys;
use aes::cipher::{BlockDecrypt, KeyInit, KeyIvInit, StreamCipher};
use aes::Aes128;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use xts_mode::Xts128;

type Aes128Ctr = ctr::Ctr128BE<Aes128>;

#[derive(Clone)]
pub struct Line {
    pub ok: bool,
    pub text: String,
}

#[derive(Clone)]
pub struct FileReport {
    pub name: String,
    pub role: String,
    pub ok: bool,
    pub lines: Vec<Line>,
}

#[derive(Clone)]
pub struct Validation {
    pub ok: bool,
    pub summary: Vec<Line>,
    pub files: Vec<FileReport>,
}

struct Entry {
    name: String,
    offset: u64,
    size: u64,
}

const GAME_EXTS: [&str; 4] = ["nsp", "xci", "nsz", "xcz"];

pub fn game_files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.extension().and_then(|e| e.to_str()).is_some_and(|e| GAME_EXTS.contains(&e.to_ascii_lowercase().as_str()))
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

pub fn validate(dir: &Path, keys_path: &Path) -> Validation {
    let mut summary = Vec::new();
    let fail = |summary: Vec<Line>| Validation { ok: false, summary, files: vec![] };
    let keys = match Keys::load(keys_path) {
        Ok(k) => k,
        Err(e) => return fail(vec![Line { ok: false, text: e }]),
    };
    let mk = keys.newest_master_key().map(|m| format!(", master keys up to {m:02x}")).unwrap_or_default();
    summary.push(Line { ok: true, text: format!("prod.keys read: {} keys{mk}", keys.len()) });
    let Some(header_key) = keys.key32("header_key") else {
        summary.push(Line { ok: false, text: "prod.keys has no header_key (32 bytes): no NCA can be read".into() });
        return fail(summary);
    };
    let files = game_files(dir);
    if files.is_empty() {
        summary.push(Line { ok: false, text: format!("no .nsp, .xci, .nsz or .xcz files in {}", dir.display()) });
        return fail(summary);
    }

    let mut reports = Vec::new();
    let mut titles: Vec<(u64, String)> = Vec::new();
    for f in &files {
        let (rep, tid) = check_file(f, &keys, &header_key);
        if let Some(t) = tid {
            titles.push((t, rep.role.clone()));
        }
        reports.push(rep);
    }

    // one game per folder, with a base game, as the script requires
    let apps: std::collections::BTreeSet<u64> = titles.iter().map(|(t, _)| app_of(*t)).collect();
    let mut ok = reports.iter().all(|r| r.ok);
        match apps.len() {
        0 => {
            summary.push(Line { ok: false, text: "no title ID could be read from any file".into() });
            ok = false;
        }
        1 => {
            let app = *apps.iter().next().unwrap();
            let has_base = titles.iter().any(|(t, _)| *t == app);
            summary.push(Line { ok: has_base, text: format!("game {app:016X}{}", if has_base { "" } else { ": no base game in the folder" }) });
            ok &= has_base;
        }
        _ => {
            let list: Vec<String> = apps.iter().map(|a| format!("{a:016X}")).collect();
            summary.push(Line { ok: false, text: format!("more than one game in the folder ({}); keep one game per folder", list.join(", ")) });
            ok = false;
        }
    }
    let bad = reports.iter().filter(|r| !r.ok).count();
    summary.push(Line {
        ok: bad == 0,
        text: if bad == 0 { format!("{} file(s) decrypt with these keys", reports.len()) } else { format!("{bad} of {} file(s) failed", reports.len()) },
    });
    Validation { ok, summary, files: reports }
}

fn app_of(tid: u64) -> u64 {
    match tid & 0xFFF {
        0 => tid,
        0x800 => tid & !0xFFF,
        _ => (tid & !0xFFF) - 0x1000,
    }
}

fn role_of(tid: u64, name: &str) -> String {
    match tid & 0xFFF {
        0 => "base game".into(),
        0x800 => match version_tag(name) {
            Some(v) => format!("update v{v}"),
            None => "update".into(),
        },
        _ => "DLC".into(),
    }
}

fn version_tag(name: &str) -> Option<u64> {
    let i = name.find("[v")?;
    let rest = &name[i + 2..];
    rest[..rest.find(']')?].parse().ok()
}

fn tag_title(name: &str) -> Option<u64> {
    let bytes = name.as_bytes();
    (0..bytes.len().saturating_sub(17)).find_map(|i| {
        if bytes[i] == b'[' && bytes.get(i + 17) == Some(&b']') {
            u64::from_str_radix(&name[i + 1..i + 17], 16).ok()
        } else {
            None
        }
    })
}

fn check_file(path: &Path, keys: &Keys, header_key: &[u8; 32]) -> (FileReport, Option<u64>) {
    let name = path.file_name().unwrap().to_string_lossy().to_string();
    let mut lines = Vec::new();
    let mut rep = |ok: bool, text: String| lines.push(Line { ok, text });
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let compressed = ext == "nsz" || ext == "xcz";

    let result = (|| -> Result<(Option<u64>, bool), String> {
        let mut f = File::open(path).map_err(|e| format!("cannot open: {e}"))?;
        if f.metadata().map(|m| m.len()).unwrap_or(0) == 0 {
            return Err("empty file (an incomplete download?)".into());
        }
        let entries = if ext == "xci" || ext == "xcz" { xci_secure(&mut f)? } else { pfs0(&mut f, 0)? };
        let tickets: Vec<Vec<u8>> = entries
            .iter()
            .filter(|e| e.name.ends_with(".tik"))
            .filter_map(|e| read_at(&mut f, e.offset, e.size.min(0x400) as usize).ok())
            .collect();
        let mut tid = tickets.iter().find_map(|t| ticket_rights(t).map(|r| u64::from_be_bytes(r[..8].try_into().unwrap())));
        let mut all_ok = true;
        let mut ncas = 0;
        for e in entries.iter().filter(|e| e.name.ends_with(".nca") || e.name.ends_with(".ncz")) {
            ncas += 1;
            match check_nca(&mut f, e, keys, header_key, &tickets, compressed || e.name.ends_with(".ncz")) {
                Ok(n) => {
                    if tid.is_none() && n.content_type == 1 {
                        tid = Some(n.program_id); // the Meta NCA names the content's title
                    }
                    rep(true, format!("{}: {}", short(&e.name), n.note));
                }
                Err(msg) => {
                    all_ok = false;
                    rep(false, format!("{}: {msg}", short(&e.name)));
                }
            }
        }
        if ncas == 0 {
            return Err("no NCA inside".into());
        }
        Ok((tid.or_else(|| tag_title(&name)), all_ok))
    })();

    match result {
        Ok((tid, ok)) => {
            let role = tid.map(|t| role_of(t, &name)).unwrap_or_else(|| "unknown title".into());
            (FileReport { name, role, ok, lines }, tid)
        }
        Err(e) => {
            lines.push(Line { ok: false, text: e });
            (FileReport { name, role: "unreadable".into(), ok: false, lines }, None)
        }
    }
}

fn short(n: &str) -> String {
    if n.len() > 14 { format!("{}…{}", &n[..6], &n[n.len() - 8..]) } else { n.to_string() }
}

fn read_at(f: &mut File, off: u64, len: usize) -> Result<Vec<u8>, String> {
    let mut b = vec![0u8; len];
    f.seek(SeekFrom::Start(off)).map_err(|e| e.to_string())?;
    f.read_exact(&mut b).map_err(|e| format!("short read at {off:#x}: {e}"))?;
    Ok(b)
}

fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

/// PFS0 at `base`: the files inside, with absolute offsets.
fn pfs0(f: &mut File, base: u64) -> Result<Vec<Entry>, String> {
    let h = read_at(f, base, 16)?;
    if &h[..4] != b"PFS0" {
        return Err("not an NSP (no PFS0 header)".into());
    }
    let (n, st) = (u32le(&h, 4) as usize, u32le(&h, 8) as usize);
    if n > 10_000 {
        return Err("PFS0 header is damaged".into());
    }
    let t = read_at(f, base + 16, n * 0x18 + st)?;
    let strs = &t[n * 0x18..];
    let data = base + 16 + (n * 0x18 + st) as u64;
    (0..n)
        .map(|i| {
            let e = &t[i * 0x18..];
            let no = u32le(e, 0x10) as usize;
            let end = strs[no..].iter().position(|&c| c == 0).map(|p| no + p).unwrap_or(strs.len());
            Ok(Entry { name: String::from_utf8_lossy(&strs[no..end]).to_string(), offset: data + u64le(e, 0), size: u64le(e, 8) })
        })
        .collect()
}

/// HFS0 at `base` (an XCI's partitions).
fn hfs0(f: &mut File, base: u64) -> Result<Vec<Entry>, String> {
    let h = read_at(f, base, 16)?;
    if &h[..4] != b"HFS0" {
        return Err("no HFS0 partition header".into());
    }
    let (n, st) = (u32le(&h, 4) as usize, u32le(&h, 8) as usize);
    if n > 10_000 {
        return Err("HFS0 header is damaged".into());
    }
    let t = read_at(f, base + 16, n * 0x40 + st)?;
    let strs = &t[n * 0x40..];
    let data = base + 16 + (n * 0x40 + st) as u64;
    (0..n)
        .map(|i| {
            let e = &t[i * 0x40..];
            let no = u32le(e, 0x10) as usize;
            let end = strs[no..].iter().position(|&c| c == 0).map(|p| no + p).unwrap_or(strs.len());
            Ok(Entry { name: String::from_utf8_lossy(&strs[no..end]).to_string(), offset: data + u64le(e, 0), size: u64le(e, 8) })
        })
        .collect()
}

fn xci_secure(f: &mut File) -> Result<Vec<Entry>, String> {
    let h = read_at(f, 0x100, 0x40)?;
    if &h[..4] != b"HEAD" {
        return Err("not an XCI (no HEAD magic)".into());
    }
    let root = u64le(&h, 0x30);
    let secure = hfs0(f, root)?.into_iter().find(|e| e.name == "secure").ok_or("the XCI has no secure partition")?;
    hfs0(f, secure.offset)
}

/// The rights ID of a common ticket, None for an unreadable one.
fn ticket_rights(t: &[u8]) -> Option<[u8; 16]> {
    let base = ticket_base(t)?;
    t.get(base + 0x160..base + 0x170).map(|r| r.try_into().unwrap())
}

fn ticket_base(t: &[u8]) -> Option<usize> {
    let sig = u32::from_le_bytes(t.get(..4)?.try_into().ok()?);
    let (size, pad) = match sig {
        0x10000 | 0x10003 => (0x200, 0x3C),
        0x10001 | 0x10004 => (0x100, 0x3C),
        0x10002 | 0x10005 => (0x3C, 0x40),
        _ => return None,
    };
    Some(4 + size + pad)
}

struct NcaInfo {
    content_type: u8,
    program_id: u64,
    note: String,
}

const CONTENT: [&str; 6] = ["Program", "Meta", "Control", "Manual", "Data", "PublicData"];

fn check_nca(f: &mut File, e: &Entry, keys: &Keys, header_key: &[u8; 32], tickets: &[Vec<u8>], compressed: bool) -> Result<NcaInfo, String> {
    let mut h = read_at(f, e.offset, 0xC00)?;
    let xts = Xts128::new(Aes128::new((&header_key[..16]).into()), Aes128::new((&header_key[16..]).into()));
    xts.decrypt_area(&mut h, 0x200, 0, |s| s.to_be_bytes());
    if &h[0x200..0x203] != b"NCA" {
        return Err("header does not decrypt: header_key is wrong for this file".into());
    }
    let ct = h[0x205];
    let ctype = CONTENT.get(ct as usize).copied().unwrap_or("?");
    let program_id = u64le(&h, 0x210);
    let gen_raw = h[0x206].max(h[0x220]);
    let kg = gen_raw.saturating_sub(1);
    let rights: [u8; 16] = h[0x230..0x240].try_into().unwrap();

    let body_key: [u8; 16] = if rights.iter().any(|&b| b != 0) {
        let kek_name = format!("titlekek_{kg:02x}");
        let t = tickets
            .iter()
            .find(|t| ticket_rights(t) == Some(rights))
            .ok_or("no ticket for this content in the file (and nxnative reads title keys only from tickets)")?;
        let base = ticket_base(t).unwrap();
        if t.get(base + 0x141) != Some(&0) {
            return Err("personalized ticket: needs a console-specific key, convert it to a common ticket first".into());
        }
        let kek = keys.key16(&kek_name).ok_or(format!("prod.keys lacks {kek_name} (key generation {kg:02x}: newer keys needed)"))?;
        let mut tk: [u8; 16] = t[base + 0x40..base + 0x50].try_into().unwrap();
        Aes128::new(&kek.into()).decrypt_block((&mut tk).into());
        tk
    } else {
        let area = ["application", "ocean", "system"].get(h[0x207] as usize).copied().ok_or("unknown key area index")?;
        let kak_name = format!("key_area_key_{area}_{kg:02x}");
        let kak = keys.key16(&kak_name).ok_or(format!("prod.keys lacks {kak_name} (key generation {kg:02x}: newer keys needed)"))?;
        let mut k: [u8; 16] = h[0x320..0x330].try_into().unwrap();
        Aes128::new(&kak.into()).decrypt_block((&mut k).into());
        k
    };
    let how = if rights.iter().any(|&b| b != 0) { "title key" } else { "key area" };
    let base_note = format!("{ctype} NCA, key generation {kg:02x}, {how}");
    if compressed {
        return Ok(NcaInfo { content_type: ct, program_id, note: format!("{base_note}; header and keys OK (compressed: data checked during conversion)") });
    }
    // the data: the first CTR-encrypted section with a PFS0 or RomFS (IVFC) layout must decrypt to its magic
    for i in 0..4 {
        let start = u32le(&h, 0x240 + i * 0x10) as u64 * 0x200;
        let end = u32le(&h, 0x244 + i * 0x10) as u64 * 0x200;
        if end <= start {
            continue;
        }
        let fs = &h[0x400 + i * 0x200..0x600 + i * 0x200];
        let (hash_type, enc) = (fs[3], fs[4]);
        if enc != 3 {
            continue;
        }
        let sparse = fs[0x148..0x178].iter().any(|&b| b != 0);
        let (rel, want): (u64, &[u8]) = match hash_type {
            2 => (u64le(fs, 0x40), b"PFS0"),
            3 if &fs[8..12] == b"IVFC" => (u64le(fs, 0x18 + 5 * 0x18), &[0x50, 0, 0, 0, 0, 0, 0, 0]),
            _ => continue,
        };
        let off = start + rel;
        let aligned = off & !0xF;
        let mut buf = read_at(f, e.offset + aligned, 0x20)?;
        let mut iv = [0u8; 16];
        for j in 0..8 {
            iv[j] = fs[0x147 - j];
        }
        iv[8..].copy_from_slice(&(aligned >> 4).to_be_bytes());
        Aes128Ctr::new(&body_key.into(), &iv.into()).apply_keystream(&mut buf);
        let s = (off - aligned) as usize;
        if &buf[s..s + want.len()] == want {
            return Ok(NcaInfo { content_type: ct, program_id, note: format!("{base_note}; data decrypts") });
        }
        if sparse {
            return Ok(NcaInfo { content_type: ct, program_id, note: format!("{base_note}; header OK (sparse section: data checked during conversion)") });
        }
        return Err(format!("{base_note}: the data does not decrypt ({} is wrong, or the file is damaged)", if how == "title key" { format!("titlekek_{kg:02x}") } else { "the key area key".to_string() }));
    }
    Ok(NcaInfo { content_type: ct, program_id, note: format!("{base_note}; header OK") })
}
