// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! A monotonic millisecond clock that works both natively and on
//! `wasm32-unknown-unknown` (where `std::time::Instant` panics).

#[cfg(target_arch = "wasm32")]
mod imp {
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen(inline_js = r#"
        export function __hellproof_now_ms() {
            return (typeof performance !== 'undefined' && performance.now)
                ? performance.now()
                : Date.now();
        }
    "#)]
    extern "C" {
        #[wasm_bindgen(js_name = __hellproof_now_ms)]
        fn now_ms_js() -> f64;
    }

    pub fn now_ms() -> f64 {
        now_ms_js()
    }
}

#[cfg(not(target_arch = "wasm32"))]
mod imp {
    use std::sync::OnceLock;
    use std::time::Instant;

    static ORIGIN: OnceLock<Instant> = OnceLock::new();

    pub fn now_ms() -> f64 {
        let origin = ORIGIN.get_or_init(Instant::now);
        origin.elapsed().as_secs_f64() * 1000.0
    }
}

pub use imp::now_ms;
