(() => {
  function json(value) {
    return typeof value === "string" ? JSON.parse(value) : value;
  }

  function run(canvasArg, source, layoutArg, settings = {}) {
    if (typeof settings === "function") settings = { uniforms: settings };
    const canvas = typeof canvasArg === "string"
      ? (globalThis.WebvasCanvases?.[canvasArg] || globalThis.document?.querySelector(canvasArg))
      : canvasArg;
    if (!canvas) throw new Error("WebGPU canvas not found: " + canvasArg);
    const layout = json(layoutArg);
    const params = settings.params || [];
    const images = settings.images || [];
    const panel = globalThis.document?.querySelector(settings.panel || "#params");
    const status = globalThis.document?.querySelector(settings.status || "#status");
    const values = Object.fromEntries(params.map(param => [param.name, param.default]));
    for (const param of params) {
      if (!panel || !param.range || !["float", "int"].includes(param.type)) continue;
      const label = document.createElement("label");
      const input = document.createElement("input");
      const caption = document.createElement("span");
      input.type = "range";
      input.min = param.range[0];
      input.max = param.exclude_end ? (param.type === "int" ? param.range[1] - 1 : param.range[1] - Number.EPSILON) : param.range[1];
      input.step = param.step ?? (param.type === "int" ? 1 : "any");
      input.value = param.default;
      input.addEventListener("input", () => {
        values[param.name] = Number(input.value);
        caption.textContent = param.name + ": " + input.value;
      });
      input.dispatchEvent(new Event("input"));
      label.append(caption, input);
      panel.append(label);
    }

    if (globalThis.WebvasBridge?.shaderMode) globalThis.WebvasBridge.shaderMode(typeof canvasArg === "string" ? canvasArg : "#gpu");
    let stopped = false;
    let texture;
    const imageTextures = [];
    const controller = {
      stop() {
        stopped = true;
        texture?.destroy();
        imageTextures.forEach(imageTexture => imageTexture.destroy());
      }
    };

    if (!globalThis.WebvasBridge && canvas.addEventListener) {
      const mouse = globalThis.WebvasMouse || [0, 0, 0, 0];
      const move = event => {
        const rect = canvas.getBoundingClientRect();
        mouse[0] = (event.clientX - rect.left) * canvas.width / rect.width;
        mouse[1] = canvas.height - (event.clientY - rect.top) * canvas.height / rect.height;
      };
      canvas.addEventListener("pointermove", move);
      canvas.addEventListener("pointerdown", event => { move(event); mouse[2] = mouse[0]; mouse[3] = mouse[1]; });
      canvas.addEventListener("pointerup", event => { move(event); mouse[2] = -Math.abs(mouse[2]); mouse[3] = -Math.abs(mouse[3]); });
      globalThis.WebvasMouse = mouse;
    }

    async function start() {
      if (!globalThis.navigator?.gpu) throw new Error("WebGPU is unavailable in this browser context");
      const adapter = await navigator.gpu.requestAdapter();
      if (!adapter) throw new Error("No WebGPU adapter is available");
      const device = await adapter.requestDevice();
      const context = canvas.getContext("webgpu");
      if (!context) throw new Error("WebGPU canvas context is unavailable");
      const format = navigator.gpu.getPreferredCanvasFormat();
      context.configure({ device, format, alphaMode: "opaque" });
      const compute = device.createComputePipeline({
        layout: "auto",
        compute: { module: device.createShaderModule({ code: source }), entryPoint: "main" }
      });
      const imageBindings = [];
      for (const [index, image] of images.entries()) {
        const bitmap = await createImageBitmap(await (await fetch(image.data)).blob());
        const imageTexture = device.createTexture({
          size: [bitmap.width, bitmap.height], format: "rgba8unorm",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
        });
        imageTextures.push(imageTexture);
        device.queue.copyExternalImageToTexture({ source: bitmap }, { texture: imageTexture }, [bitmap.width, bitmap.height]);
        imageBindings.push(
          { binding: 2 + index * 2, resource: imageTexture.createView() },
          { binding: 3 + index * 2, resource: device.createSampler({ magFilter: "linear", minFilter: "linear", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge" }) }
        );
        bitmap.close();
      }
      const presentSource = [
        "@group(0) @binding(0) var image: texture_2d<f32>;",
        "@vertex fn vs(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32>{var p=array<vec2<f32>,3>(vec2(-1.0,-1.0),vec2(3.0,-1.0),vec2(-1.0,3.0));return vec4(p[i],0.0,1.0);}",
        "@fragment fn fs(@builtin(position) p:vec4<f32>)->@location(0) vec4<f32>{return textureLoad(image,vec2<i32>(p.xy),0);}"
      ].join("\n");
      const present = device.createRenderPipeline({
        layout: "auto",
        vertex: { module: device.createShaderModule({ code: presentSource }), entryPoint: "vs" },
        fragment: { module: device.createShaderModule({ code: presentSource }), entryPoint: "fs", targets: [{ format }] },
        primitive: { topology: "triangle-list" }
      });
      const uniform = device.createBuffer({ size: layout.size, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
      let computeGroup;
      let presentGroup;
      let frame = 0;

      function resize() {
        const ratio = globalThis.devicePixelRatio || 1;
        const width = Math.max(1, Math.round((canvas.clientWidth || canvas.width) * ratio));
        const height = Math.max(1, Math.round((canvas.clientHeight || canvas.height) * ratio));
        if (canvas.width === width && canvas.height === height && texture) return;
        canvas.width = width;
        canvas.height = height;
        texture?.destroy();
        texture = device.createTexture({
          size: [width, height], format: "rgba8unorm",
          usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING
        });
        const view = texture.createView();
        computeGroup = device.createBindGroup({ layout: compute.getBindGroupLayout(0), entries: [
          { binding: 0, resource: { buffer: uniform } }, { binding: 1, resource: view }, ...imageBindings
        ] });
        presentGroup = device.createBindGroup({ layout: present.getBindGroupLayout(0), entries: [{ binding: 0, resource: view }] });
      }

      function draw(now) {
        if (stopped) return;
        resize();
        const data = new ArrayBuffer(layout.size);
        const view = new DataView(data);
        const put = (name, value) => {
          const field = layout.fields[name];
          if (!field) return;
          const items = Array.isArray(value) ? value : [value];
          items.forEach((item, index) => {
            const offset = field.offset + index * 4;
            if (["int", "bool"].includes(field.type)) view.setInt32(offset, Number(item), true);
            else view.setFloat32(offset, Number(item), true);
          });
        };
        put("resolution", [canvas.width, canvas.height]);
        put("time", now / 1000);
        put("frame", frame++);
        put("mouse", globalThis.WebvasMouse || [0, 0, 0, 0]);
        const dynamic = settings.uniforms ? settings.uniforms(now / 1000) : (settings.values || values);
        const current = json(dynamic || {});
        for (const param of params) put(param.name, current[param.name] ?? values[param.name]);
        for (const [name, value] of Object.entries(current)) put(name, value);
        device.queue.writeBuffer(uniform, 0, data);
        const encoder = device.createCommandEncoder();
        const pass = encoder.beginComputePass();
        pass.setPipeline(compute);
        pass.setBindGroup(0, computeGroup);
        pass.dispatchWorkgroups(Math.ceil(canvas.width / 8), Math.ceil(canvas.height / 8));
        pass.end();
        const render = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store" }] });
        render.setPipeline(present);
        render.setBindGroup(0, presentGroup);
        render.draw(3);
        render.end();
        device.queue.submit([encoder.finish()]);
        requestAnimationFrame(draw);
      }

      device.lost.then(info => {
        stopped = true;
        if (status) status.textContent = "WebGPU device lost: " + info.message;
      });
      requestAnimationFrame(draw);
      return controller;
    }

    start().catch(error => {
      if (status) status.textContent = error.message;
      globalThis.WebvasBridge?.showError(error.message, error.stack || "");
    });
    return controller;
  }

  globalThis.GlazeWGSL = { run };
})();
