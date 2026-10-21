use crate::{
    Result,
    control::{Gain, Status},
};
use std::{
    ffi::{c_char, c_void},
    marker::PhantomData,
    ptr::NonNull,
    rc::Rc,
};

#[repr(C)]
struct NativeStatus {
    sample_rate: f64,
    latency_ms: f64,
    callbacks: u64,
    faults: u64,
    gain_db: f32,
    active: u32,
    buffer_frames: u32,
    device: [c_char; 256],
    error: [c_char; 512],
}

unsafe extern "C" {
    fn ab_engine_create() -> *mut c_void;
    fn ab_engine_start(engine: *mut c_void, gain: f32) -> i32;
    fn ab_engine_set_gain(engine: *mut c_void, gain: f32);
    fn ab_engine_poll(engine: *mut c_void) -> i32;
    fn ab_engine_status(engine: *mut c_void, status: *mut NativeStatus);
    fn ab_engine_stop(engine: *mut c_void) -> i32;
    fn ab_engine_destroy(engine: *mut c_void);
    fn ab_run_loop(seconds: f64);
}

// Core Audio objects are created, reconfigured, and destroyed on the service thread.
pub(crate) struct Engine {
    pointer: NonNull<c_void>,
    _thread: PhantomData<Rc<()>>,
}

impl Engine {
    pub fn new() -> Result<Self> {
        // SAFETY: no arguments; native constructor returns null or a uniquely owned engine.
        let pointer =
            NonNull::new(unsafe { ab_engine_create() }).ok_or("could not allocate audio engine")?;
        Ok(Self {
            pointer,
            _thread: PhantomData,
        })
    }
    pub fn start(&mut self, gain: Gain) -> Result<()> {
        // SAFETY: self owns the engine and Gain enforces the native finite 0..=12 contract.
        if unsafe { ab_engine_start(self.pointer.as_ptr(), gain.db()) } != 0 {
            return Err(self.status().error.into());
        }
        Ok(())
    }
    pub fn set_gain(&mut self, gain: Gain) {
        // SAFETY: live engine, valid gain, called only on its owning thread.
        unsafe { ab_engine_set_gain(self.pointer.as_ptr(), gain.db()) };
    }
    pub fn poll(&mut self) -> Result<()> {
        // SAFETY: &mut self excludes simultaneous control operations on this engine.
        if unsafe { ab_engine_poll(self.pointer.as_ptr()) } != 0 {
            return Err(self.status().error.into());
        }
        Ok(())
    }
    pub fn stop(&mut self) -> Result<()> {
        // SAFETY: live, uniquely owned engine; native stop waits for callback completion.
        if unsafe { ab_engine_stop(self.pointer.as_ptr()) } != 0 {
            return Err(self.status().error.into());
        }
        Ok(())
    }
    pub fn status(&self) -> Status {
        let mut status = NativeStatus {
            sample_rate: 0.0,
            latency_ms: 0.0,
            callbacks: 0,
            faults: 0,
            gain_db: 0.0,
            active: 0,
            buffer_frames: 0,
            device: [0; 256],
            error: [0; 512],
        };
        // SAFETY: both pointers are live, correctly aligned, and native writes exactly NativeStatus.
        unsafe { ab_engine_status(self.pointer.as_ptr(), &mut status) };
        let text = |bytes: &[c_char]| {
            String::from_utf8_lossy(
                &bytes
                    .iter()
                    .take_while(|&&b| b != 0)
                    .map(|&b| b as u8)
                    .collect::<Vec<_>>(),
            )
            .into_owned()
        };
        let error = text(&status.error);
        Status {
            state: if status.active == 2 {
                "sleeping"
            } else if status.active == 1 {
                "active"
            } else if error.is_empty() {
                "idle"
            } else {
                "error"
            }
            .into(),
            gain_db: status.gain_db,
            device: text(&status.device),
            sample_rate: status.sample_rate,
            latency_ms: status.latency_ms,
            buffer_frames: status.buffer_frames,
            callbacks: status.callbacks,
            faults: status.faults,
            error,
            pid: std::process::id(),
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: this is the unique owner; native destruction stops callbacks before freeing buffers.
        unsafe { ab_engine_destroy(self.pointer.as_ptr()) };
    }
}

pub(crate) fn wait_events() {
    // SAFETY: services the owning thread's CFRunLoop for a finite interval.
    unsafe { ab_run_loop(0.05) };
}
