//! Explicit, user-operated live QA sender. Posts only with --run-live and a
//! separately authorized native receiver. Not part of automated cargo tests.
use std::{
    error::Error,
    time::{Duration, Instant},
};
use viewflow_protocol::{PROTOCOL_VERSION, wire};
use viewflow_transport::{
    ControlSequencer, PeerIdentity, build_server_config, receive_control_sequenced, send_control,
};
type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
type Payload = wire::control_envelope::Payload;

fn id(low: u64) -> wire::Id128 {
    wire::Id128 { high: 0, low }
}
fn key(usage: u32, down: bool) -> wire::input_event::Event {
    wire::input_event::Event::KeyboardHidUsage(wire::KeyboardHidUsage {
        usage_page: 7,
        usage_id: usage,
        state: if down { 1 } else { 2 },
        repeat: false,
    })
}
fn button(down: bool) -> wire::input_event::Event {
    wire::input_event::Event::PointerButton(wire::PointerButtonEvent {
        button: 1,
        state: if down { 1 } else { 2 },
    })
}
fn position(x: f64, y: f64) -> wire::input_event::Event {
    wire::input_event::Event::DesktopPointerPosition(wire::DesktopPointerPosition {
        x_millidip: (x * 1000.0) as i64,
        y_millidip: (y * 1000.0) as i64,
    })
}
async fn send(c: &quinn::Connection, seq: &mut u64, payload: Payload) -> Result<()> {
    *seq += 1;
    send_control(
        c,
        &wire::ControlEnvelope {
            protocol_major: u32::from(PROTOCOL_VERSION.major),
            protocol_minor: u32::from(PROTOCOL_VERSION.minor),
            sequence: *seq,
            payload: Some(payload),
        },
    )
    .await?;
    Ok(())
}
#[tokio::main]
async fn main() -> Result<()> {
    let a: Vec<_> = std::env::args().collect();
    if a.len() != 8 || a[1] != "--run-live" {
        return Err("usage: macos_input_live --run-live CERT KEY CA BIND TARGET_X TARGET_Y".into());
    }
    let identity = PeerIdentity::from_pem(
        &std::fs::read(&a[2])?,
        &std::fs::read(&a[3])?,
        &std::fs::read(&a[4])?,
    )?;
    let endpoint = quinn::Endpoint::server(build_server_config(&identity)?, a[5].parse()?)?;
    let x: f64 = a[6].parse()?;
    let y: f64 = a[7].parse()?;
    let origin = Instant::now();
    let now = || u64::try_from(origin.elapsed().as_nanos()).unwrap();
    println!("listening={}", endpoint.local_addr()?);
    let c = tokio::time::timeout(Duration::from_secs(30), endpoint.accept())
        .await?
        .ok_or("listener closed")?
        .await?;
    println!("authenticated={}", c.remote_address());
    let mut plan = vec![position(x, y)];
    // Exact expected text: vfTest; no command/control shortcuts.
    for usage in [0x19, 0x09] {
        plan.extend([key(usage, true), key(usage, false)]);
    }
    plan.extend([
        key(0xe1, true),
        key(0x17, true),
        key(0x17, false),
        key(0xe1, false),
    ]);
    for usage in [0x08, 0x16, 0x17] {
        plan.extend([key(usage, true), key(usage, false)]);
    }
    plan.extend([
        button(true),
        button(false),
        button(true),
        button(false),
        button(true),
        position(x + 20.0, y + 10.0),
        position(x + 40.0, y + 20.0),
        position(x + 60.0, y + 30.0),
        button(false),
    ]);
    for (v, h) in [(-0.5, 0.0), (0.0, 0.5)] {
        plan.push(wire::input_event::Event::PointerWheel(
            wire::PointerWheelEvent {
                vertical_delta_detents: v,
                horizontal_delta_detents: h,
            },
        ));
    }
    // End with a held Shift and left button inside the fixture. Disconnect
    // must generate their releases through the native receiver's cleanup.
    plan.extend([key(0xe1, true), button(true)]);
    let mut out = 0;
    let (tx, mut incoming) = tokio::sync::mpsc::channel(16);
    let reader_connection = c.clone();
    tokio::spawn(async move {
        let mut sequencer = ControlSequencer::default();
        loop {
            let result = receive_control_sequenced(&reader_connection, &mut sequencer).await;
            let failed = result.is_err();
            if tx.send(result).await.is_err() || failed {
                break;
            }
        }
    });
    let mut sent = 0;
    let mut pending = None;
    let mut leased = false;
    let ready = Instant::now() + Duration::from_secs(3);
    let mut tick = tokio::time::interval(Duration::from_millis(150));
    let timeout = tokio::time::sleep(Duration::from_secs(30));
    tokio::pin!(timeout);
    loop {
        tokio::select! {
            _ = &mut timeout => return Err("live test timed out; dropping connection for held-input cleanup".into()),
            envelope = incoming.recv() => {
                match envelope.ok_or("reader closed")??.payload.ok_or("missing payload")? {
                    Payload::ClockSyncProbe(p) => {
                        let t = now();
                        send(&c,&mut out,Payload::ClockSyncReply(wire::ClockSyncReply { probe_id:p.probe_id,t0_send_ns:p.t0_send_ns,t1_receive_ns:t,t2_send_ns:now() })).await?;
                    }
                    Payload::InputAppliedAck(ack) => {
                        if pending != Some(ack.event_sequence) || ack.result != wire::InputAppliedResult::Applied as i32 {
                            return Err(format!("rejected or unexpected ACK: {ack:?}").into());
                        }
                        println!("applied={}",ack.event_sequence); pending = None;
                    }
                    _ => {}
                }
            }
            _ = tick.tick(), if Instant::now() >= ready && pending.is_none() => {
                if !leased {
                    for (generation,state) in [(1,wire::InputLeaseState::Offered),(2,wire::InputLeaseState::Active)] {
                        send(&c,&mut out,Payload::InputLease(wire::InputLease { generation, owner:Some(id(1)), route_to:Some(id(2)), state:state as i32 })).await?;
                    }
                    leased = true;
                }
                if sent == plan.len() {
                    println!("disconnecting_with_shift_and_left_held=true");
                    c.close(0_u32.into(),b"live test complete; verify held-input cleanup");
                    endpoint.wait_idle().await;
                    return Ok(());
                }
                sent+=1; pending=Some(sent as u64);
                send(&c,&mut out,Payload::InputEvent(wire::InputEvent { lease_generation:2,target_device:Some(id(2)),event_sequence:sent as u64,sender_not_after_ns:now()+2_000_000_000,event:Some(plan[sent-1].clone()) })).await?;
            }
        }
    }
}
