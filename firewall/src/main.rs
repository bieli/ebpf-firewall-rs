use aya::programs::TracePoint;
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/firewall"
    )))?;

    let program: &mut TracePoint = ebpf.program_mut("firewall").unwrap().try_into()?;
    program.load()?;
    program.attach("syscalls", "sys_enter_execve")?;

    println!("loaded. Watch: sudo cat /sys/kernel/tracing/trace_pipe");
    println!("Press Ctrl-C to exit.");
    signal::ctrl_c().await?;
    Ok(())
}
