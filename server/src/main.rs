fn main() -> Result<(), String> {
    for frame in watchparty_sync::harness::scenario()? { println!("{}", frame); }
    Ok(())
}
