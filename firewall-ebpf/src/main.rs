#![no_std]
#![no_main]

use aya_ebpf::{helpers::bpf_printk, macros::tracepoint, programs::TracePointContext};
use aya_log_ebpf::info;

#[tracepoint]
pub fn firewall(ctx: TracePointContext) -> u32 {
    // aya-log: shows up in the loader's stdout (RUST_LOG=info).
    info!(&ctx, "execve called");
    // bpf_printk: the classic kernel primitive, seen via
    // `sudo cat /sys/kernel/tracing/trace_pipe`.
    unsafe { bpf_printk!(c"hello from eBPF: execve called") };
    0
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
