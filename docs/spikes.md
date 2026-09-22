# Glaze implementation checks

These checks record the results of the design spikes that can run without a
browser or a Metal device.

| Check | Result | Evidence |
|---|---|---|
| Forward a fragment block through another object | Pass | `spec/glaze_spec.rb` covers `Definition#rlsl_builder` and helper/function forwarding. |
| Load the same file twice after editing it | Pass | `Loader` uses `load(path, true)` and clears the definition registry; `Watcher` hashes Ruby tokens. |
| Pack integer and vector uniforms | Pass for CPU and source generation | CPU rendering and RLSL MSL/WGSL generation are covered by the Glaze and RLSL suites. GPU execution requires a Metal session. |
| Resolve WGSL integer and boolean layout | Pass | `Export::UniformLayout` uses 4-byte scalar slots and 16-byte vector alignment; export specs cover generated bindings. |
| Use a Cocoa native handle with the Metal runner | Wired, GPU validation pending | `Runners::Metal` calls `build_metal_shader`, `prepare`, and `render_metal`; the mandatory GPU workflow is `run_metal`. |

The last check must be repeated on a logged-in macOS session with a Metal
device. Headless CI intentionally omits it.
