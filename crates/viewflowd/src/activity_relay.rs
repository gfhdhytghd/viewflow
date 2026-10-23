//! Independent native encoded media writers. Input remains one ordered stream.
use std::{sync::{Arc, Mutex}, time::{Duration, Instant}};
use anyhow::{Result, ensure};
use tokio::{io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt}, sync::{Notify, mpsc, watch}};
use crate::activity_media::{EncodedRecord, LaneQueue};
const MAX_RECORD: usize = 96 * 1024 * 1024;

async fn read_record<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>> {
    let length = reader.read_u32_le().await? as usize;
    ensure!((4..=MAX_RECORD).contains(&length), "activity record length");
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).await?;
    Ok(bytes)
}
async fn write_record<W: AsyncWrite + Unpin>(writer: &mut W, bytes: &[u8]) -> Result<()> {
    writer.write_all(&(bytes.len() as u32).to_le_bytes()).await?;
    writer.write_all(bytes).await?;
    writer.flush().await?;
    Ok(())
}
#[derive(Clone, Copy, Default)]
struct Feedback { request_idr: bool, age_us: u64, saturated: bool }
impl Feedback {
    fn record(self, lane: usize) -> Vec<u8> {
        let mut bytes = 5u32.to_le_bytes().to_vec();
        bytes.extend((lane as u32).to_le_bytes());
        bytes.extend((u32::from(self.request_idr) | u32::from(self.saturated)<<1).to_le_bytes());
        bytes.extend(0u32.to_le_bytes());
        bytes.extend(self.age_us.to_le_bytes());
        bytes
    }
}
struct SharedLane { queue: Mutex<LaneQueue>, ready: Notify, in_flight: Mutex<Option<Instant>> }
async fn write_lane<W: AsyncWrite + Unpin>(lane: &SharedLane, writer: &mut W) -> Result<()> {
    loop {
        // Register before checking the queue so a concurrent producer cannot
        // leave a record asleep. No lock is held across network backpressure.
        let notified = lane.ready.notified();
        let record = lane.queue.lock().unwrap().pop();
        if let Some(record) = record {
            *lane.in_flight.lock().unwrap()=Some(record.queued);
            write_record(writer, &record.bytes).await?;
            *lane.in_flight.lock().unwrap()=None;
        }
        else { notified.await; }
    }
}

pub(crate) async fn source<R, W>(output: &mut R, input: &mut W,
    background: &mut quinn::SendStream, priority: &mut quinn::SendStream,
    incoming: &mut quinn::RecvStream) -> Result<()>
where R: AsyncRead + Unpin, W: AsyncWrite + Unpin {
    background.set_priority(0)?; priority.set_priority(10)?;
    let lanes: [Arc<SharedLane>; 2] = std::array::from_fn(|_| Arc::new(SharedLane {
        queue: Mutex::new(LaneQueue::new(3, 24*1024*1024)), ready: Notify::new(), in_flight: Mutex::new(None) }));
    let (feedback, mut updates) = watch::channel([Feedback::default(); 2]);
    let collect = async {
        loop {
            let bytes = read_record(output).await?;
            let (index, record) = EncodedRecord::parse(bytes, Instant::now())?;
            let mut queue = lanes[index].queue.lock().unwrap();
            let request_idr = queue.push(record);
            feedback.send_modify(|state| state[index] = Feedback {
                request_idr, age_us: queue.age(Instant::now()).as_micros().min(u64::MAX as u128) as u64,
                saturated: queue.saturated() });
            drop(queue);
            lanes[index].ready.notify_one();
        }
        #[allow(unreachable_code)] Ok::<(), anyhow::Error>(())
    };
    // A bounded message channel preserves read progress when feedback becomes
    // ready in the middle of a network record.
    let (events, mut pending_events) = mpsc::channel::<Vec<u8>>(4);
    let receive_input = async {
        loop {
            let bytes = read_record(incoming).await?;
            let tag = u32::from_le_bytes(bytes[..4].try_into()?);
            ensure!((tag == 2 && bytes.len() == 40) || (tag == 3 && (48..=64*1024*1024).contains(&bytes.len()))
                || ((tag == 5 || tag == 6) && bytes.len() == 24), "activity input record");
            events.send(bytes).await.map_err(|_| anyhow::anyhow!("activity input closed"))?;
        }
        #[allow(unreachable_code)] Ok::<(), anyhow::Error>(())
    };
    let feed_native = async {
        let mut sample = tokio::time::interval(Duration::from_millis(250));
        loop {
            tokio::select! {
                event = pending_events.recv() => {
                    let event = event.ok_or_else(|| anyhow::anyhow!("activity input EOF"))?;
                    write_record(input, &event).await?;
                }
                _ = sample.tick() => {
                    let snapshot = *updates.borrow_and_update();
                    for (index, mut state) in snapshot.into_iter().enumerate() {
                        { let queue = lanes[index].queue.lock().unwrap();
                          state.age_us = queue.age(Instant::now()).as_micros().min(u64::MAX as u128) as u64;
                          state.saturated = queue.saturated(); }
                        if let Some(started)=*lanes[index].in_flight.lock().unwrap() {
                            state.age_us=state.age_us.max(started.elapsed().as_micros().min(u64::MAX as u128) as u64);
                        }
                        write_record(input, &state.record(index)).await?;
                    }
                }
                changed = updates.changed() => {
                    changed?;
                    let snapshot = *updates.borrow_and_update();
                    for (index, state) in snapshot.into_iter().enumerate() {
                        if state.request_idr { write_record(input, &state.record(index)).await?; }
                    }
                }
            }
        }
        #[allow(unreachable_code)] Ok::<(), anyhow::Error>(())
    };
    tokio::select! {
        result = collect => result,
        result = write_lane(&lanes[0], background) => result,
        result = write_lane(&lanes[1], priority) => result,
        result = receive_input => result,
        result = feed_native => result,
    }
}

pub(crate) async fn presenter<W: AsyncWrite + Unpin>(background: &mut quinn::RecvStream,
    priority: &mut quinn::RecvStream, input: &mut W) -> Result<()> {
    let (bg_send, mut bg_recv) = mpsc::channel::<Vec<u8>>(1);
    let (fg_send, mut fg_recv) = mpsc::channel::<Vec<u8>>(1);
    async fn receive(reader: &mut quinn::RecvStream, sender: mpsc::Sender<Vec<u8>>, lane: usize) -> Result<()> {
        loop {
            let bytes = read_record(reader).await?;
            let (actual, record) = EncodedRecord::parse(bytes, Instant::now())?;
            ensure!(actual == lane, "activity media lane mismatch");
            sender.send(record.bytes).await.map_err(|_| anyhow::anyhow!("activity decoder pipe closed"))?;
        }
    }
    let present = async {
        let mut last_background = Instant::now();
        loop {
            // Bounded fairness is a service opportunity, not a frame deadline.
            if last_background.elapsed() >= Duration::from_millis(200) {
                if let Ok(bytes) = bg_recv.try_recv() {
                    write_record(input, &bytes).await?;
                    last_background = Instant::now();
                    continue;
                }
            }
            tokio::select! {
                biased;
                bytes = fg_recv.recv() => write_record(input, &bytes.ok_or_else(|| anyhow::anyhow!("priority EOF"))?).await?,
                bytes = bg_recv.recv() => {
                    write_record(input, &bytes.ok_or_else(|| anyhow::anyhow!("background EOF"))?).await?;
                    last_background = Instant::now();
                }
            }
        }
        #[allow(unreachable_code)] Ok::<(), anyhow::Error>(())
    };
    tokio::select! {
        result = receive(background, bg_send, 0) => result,
        result = receive(priority, fg_send, 1) => result,
        result = present => result,
    }
}
