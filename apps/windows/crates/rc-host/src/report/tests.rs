use super::*;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rc-host-log-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn the_log_rotates_once_and_keeps_only_the_newest_copy() {
    let dir = scratch("rotate");
    let mut log = LogFile::open(dir.join("rc-host.log"), 100).unwrap();
    for i in 0..12 {
        log.append(&format!("line {i:02} ........"));
    }
    let current = std::fs::read_to_string(dir.join("rc-host.log")).unwrap();
    let rotated = std::fs::read_to_string(log.rotated_path()).unwrap();
    assert!(current.len() <= 100 && rotated.len() <= 100);
    assert!(current.ends_with("line 11 ........\r\n"));
    assert!(!rotated.contains("line 00"), "only one rotated copy is kept");
    assert!(!dir.join("rc-host.log.1.1").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_reopened_log_keeps_appending_and_counts_what_is_already_there() {
    let dir = scratch("reopen");
    let path = dir.join("rc-host.log");
    LogFile::open(path.clone(), 1000).unwrap().append("first");
    let mut log = LogFile::open(path.clone(), 12).unwrap();
    log.append("second");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "second\r\n");
    assert_eq!(std::fs::read_to_string(log.rotated_path()).unwrap(), "first\r\n");
    let _ = std::fs::remove_dir_all(&dir);
}
