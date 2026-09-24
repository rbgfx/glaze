# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rbconfig"
require "flipbook"

RSpec.describe Glaze do
  it "has a version number" do
    expect(Glaze::VERSION).not_to be nil
  end

  it "collects params and renders a fragment" do
    definition = Glaze.shader(:solid) do
      params { float :brightness, default: 0.5, range: 0.0..1.0 }
      fragment { |_coord, _resolution, u| [u[:brightness], 0.0, 0.0, 1.0] }
    end
    image = Glaze.render(definition, width: 1, height: 1)

    expect(definition.params.first.name).to eq(:brightness)
    expect(image[0, 0]).to eq([128, 0, 0, 255])
  ensure
    Glaze.definitions.clear
  end

  it "rejects duplicate params across blocks and clamps direct colors" do
    definition = Glaze::Definition.new(:duplicate)
    definition.params { float :gain }
    expect { definition.params { int :gain } }.to raise_error(ArgumentError, /duplicate uniform/)
    definition.fragment { [-0.2, 0.5, 300.0, 1.0] }

    expect(Glaze.render(definition, width: 1, height: 1)[0, 0]).to eq([0, 128, 255, 255])
  ensure
    Glaze.definitions.clear
  end

  it "aligns uniform fields" do
    params = [Glaze::Param.new(name: :a, type: :float), Glaze::Param.new(name: :b, type: :vec3), Glaze::Param.new(name: :c, type: :float)]

    layout = Glaze::Export::UniformLayout.build(params)

    expect(layout[:fields][:a][:offset]).to eq(0)
    expect(layout[:fields][:b][:offset]).to eq(16)
    expect(layout[:size]).to eq(32)
  end

  it "loads a shader file and renders the compiled C path with top-down RGBA pixels" do
    path = File.expand_path("../examples/gradient.rb", __dir__)
    result = Glaze::Loader.new.load(path)
    expect(result).to be_ok
    image = Glaze::Runners::CPU.new(result.definition).render(width: 2, height: 2)
    expect(image[0, 0][1]).to be > image[0, 1][1]
    expect(image[0, 0][0]).to be < image[1, 0][0]
    expect(image[0, 0][3]).to eq(255)
  end

  it "exports runnable WebGPU setup with the WGSL fragment" do
    path = File.expand_path("../examples/gradient.rb", __dir__)
    output = File.join(Dir.tmpdir, "glaze-gradient.html")
    Glaze.export_webgpu(Glaze.load_file(path), output)
    html = File.read(output)
    expect(html).to include("createComputePipeline", "texture_storage_2d", "requestAnimationFrame")
  end

  it "runs two frames through rbgl's file backend" do
    path = File.expand_path("../examples/gradient.rb", __dir__)
    Dir.mktmpdir do |dir|
      Glaze.run_file(path, width: 2, height: 2, backend: :file, frames: 2, output_dir: dir)
      expect(Dir[File.join(dir, "*.ppm")].length).to eq(2)
      expect(File.read(File.join(dir, "frame_00000.ppm"))).to start_with("P3\n2 2\n255\n")
    end
  end

  it "records shader frames as GIF or APNG when requested" do
    root = File.expand_path("..", __dir__)
    shader = File.join(root, "examples", "gradient.rb")
    Dir.mktmpdir do |directory|
      { "--gif" => "record.gif", "--apng" => "record.apng" }.each do |flag, name|
        output = File.join(directory, name)
        stdout, stderr, status = Open3.capture3(ENV.to_h, RbConfig.ruby, "-Ilib", "exe/glaze", "record", shader,
                                               flag, "--seconds", "0.2", "--fps", "10", "--size", "4x3", "-o", output, chdir: root)
        expect(status.success?).to be(true), stderr
        expect(stdout).to eq("#{output}\n")
        if flag == "--gif"
          expect(Flipbook.read(output).length).to eq(2)
        else
          expect(File.binread(output)).to include("acTL")
        end
      end
    end
  end

  it "prepares Metal shaders before use and passes frame uniforms" do
    definition = Glaze::Definition.new(:metal_test)
    definition.params { float :gain, default: 0.5 }
    shader = double("Metal shader")
    allow(definition).to receive(:rlsl_builder).and_return(double(build_metal_shader: shader))
    expect(shader).to receive(:prepare).with(:handle)
    runner = Glaze::Runners::Metal.new(definition, :handle)
    expect(shader).to receive(:render_metal).with(:handle, 2, 3, hash_including(time: 1.0, frame: 4, gain: 0.5), textures: {})
    runner.render(width: 2, height: 3, time: 1.0, frame: 4)
  end

  it "ignores nonnumeric parameter adjustments" do
    definition = Glaze::Definition.new(:controls)
    definition.params { bool :enabled, default: true }
    state = Glaze::ParamState.new(definition)
    state.adjust(1)
    expect(state.values[:enabled]).to be(true)
  end

  it "builds a Twiddle panel from numeric ranges" do
    definition = Glaze::Definition.new(:panel)
    definition.params { float :gain, default: 0.0, range: 0.0..10.0 }
    values = { gain: 0.0 }
    panel = Glaze::Runners::ParamPanel.new(definition)
    panel.render(Tessel::Image.new(300, 200), events: [{ type: :mouse_press, x: 100, y: 40 }], values: values)

    expect(values[:gain]).to be_between(0.0, 10.0)
    expect(values[:gain]).to be > 0.0
  end

  it "validates uniform declarations and honors exclusive ranges" do
    context = Glaze::ParamsContext.new
    expect { context.float(:value, default: 2, range: 0.0...1.0) }.to raise_error(ArgumentError, /outside/)
    expect { context.int(:value, default: 1, step: 0.5) }.to raise_error(TypeError, /step/)
    expect { context.bool(:value, default: 1) }.to raise_error(TypeError, /default/)

    definition = Glaze::Definition.new(:exclusive)
    definition.params { int :value, default: 0, range: 0...2 }
    state = Glaze::ParamState.new(definition)
    state.adjust(10)
    expect(state.values[:value]).to eq(1)
  end

  it "does not reload a watcher for comment or whitespace changes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "shader.rb")
      File.write(path, "Glaze.shader(:x) { fragment { 1.0 } }\n")
      watcher = Glaze::Watcher.new(path)
      expect(watcher.changed?).to be(true)
      expect(watcher.changed?).to be(false)
      File.write(path, "# comment\nGlaze.shader(:x) {\n  fragment { 1.0 }\n}\n")
      expect(watcher.changed?).to be(false)
      File.write(path, "Glaze.shader(:x) { fragment { 0.5 } }\n")
      expect(watcher.changed?).to be(true)
    end
  end

  it "keeps running when a backend reports an unmapped numeric key" do
    require "rbgl"
    window = double("window")
    allow(RBGL::GUI::Window).to receive(:new).and_return(window)
    allow(window).to receive(:metal_available?).and_return(false)
    allow(window).to receive(:should_close?).and_return(false, true)
    allow(window).to receive(:poll_events_raw).and_return([{ type: :key_press, key: 999 }])
    allow(window).to receive(:close)
    expect(window).to receive(:set_pixels).once
    Glaze.run_file(File.expand_path("../examples/gradient.rb", __dir__), width: 2, height: 2, backend: :file)
  end

  it "can force the CPU renderer without changing the window backend" do
    require "rbgl"
    window = double("window")
    expect(RBGL::GUI::Window).to receive(:new).with(hash_including(backend: :auto)).and_return(window)
    allow(window).to receive(:metal_available?).and_return(true)
    allow(window).to receive(:should_close?).and_return(false, true)
    allow(window).to receive(:poll_events_raw).and_return([])
    allow(window).to receive(:set_pixels)
    allow(window).to receive(:close)

    Glaze.run_file(File.expand_path("../examples/gradient.rb", __dir__), width: 2, height: 2, backend: :cpu)
  end

  it "saves the running shader and source when s is pressed" do
    require "rbgl"
    path = File.expand_path("../examples/gradient.rb", __dir__)
    window = double("window")
    allow(RBGL::GUI::Window).to receive(:new).and_return(window)
    allow(window).to receive(:metal_available?).and_return(false)
    allow(window).to receive(:should_close?).and_return(false, true)
    allow(window).to receive(:poll_events_raw).and_return([{ type: :key_press, key: :s, char: "s" }])
    allow(window).to receive(:set_pixels)
    allow(window).to receive(:close)

    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        Glaze.run_file(path, width: 2, height: 2, backend: :file)
        shot = Dir["shots/*.png"].fetch(0)
        expect(Tessel.read(shot).metadata["glaze:source"]).to eq(File.read(path))
      end
    end
  end

  it "loads texture params relative to the shader and releases them after Metal use" do
    require "metaco"
    Dir.mktmpdir do |directory|
      image = Tessel::Image.new(1, 1, fill: [255, 0, 0, 255])
      image.write(File.join(directory, "noise.png"))
      definition = Glaze::Definition.new(:textured)
      definition.params { texture :noise, file: "noise.png" }
      definition.instance_variable_set(:@file, File.join(directory, "shader.rb"))
      shader = double("Metal shader")
      allow(definition).to receive(:rlsl_builder).and_return(double(build_metal_shader: shader))
      expect(Metaco).to receive(:texture_create).with(:handle, 1, 1, image.bytes).and_return(:texture)
      expect(shader).to receive(:prepare).with(:handle)
      runner = Glaze::Runners::Metal.new(definition, :handle)
      expect(shader).to receive(:render_metal).with(:handle, 1, 1, hash_including(time: 0.0), textures: { noise: :texture })
      runner.render(width: 1, height: 1)
      expect(Metaco).to receive(:read_pixels).with(:handle).and_return(image.bytes)
      expect(runner.read_image(1, 1).bytes).to eq(image.bytes)
      expect(Metaco).to receive(:texture_destroy).with(:texture)
      runner.close
      expect { Glaze::Runners::CPU.new(definition) }.to raise_error(Glaze::Error, /Metal/)
    end
  end

  it "releases uploaded textures if Metal compilation fails" do
    require "metaco"
    Dir.mktmpdir do |directory|
      Tessel::Image.new(1, 1).write(File.join(directory, "noise.png"))
      definition = Glaze::Definition.new(:textured)
      definition.params { texture :noise, file: "noise.png" }
      definition.instance_variable_set(:@file, File.join(directory, "shader.rb"))
      shader = double("bad Metal shader")
      allow(definition).to receive(:rlsl_builder).and_return(double(build_metal_shader: shader))
      allow(Metaco).to receive(:texture_create).and_return(:texture)
      allow(shader).to receive(:prepare).and_raise(RuntimeError, "bad shader")
      expect(Metaco).to receive(:texture_destroy).with(:texture)

      expect { Glaze::Runners::Metal.new(definition, :handle) }.to raise_error(RuntimeError, "bad shader")
    end
  end

  it "generates an MSL input binding for the textured example" do
    definition = Glaze.load_file(File.expand_path("../examples/textured.rb", __dir__))
    expect(definition.rlsl_builder.build_metal_shader.msl_source).to include("[[texture(1)]]")
  end

  it "embeds texture bytes and sampler bindings in WebGPU exports" do
    definition = Glaze.load_file(File.expand_path("../examples/textured.rb", __dir__))
    Dir.mktmpdir do |directory|
      output = File.join(directory, "textured.html")
      Glaze.export_webgpu(definition, output)
      html = File.read(output)
      expect(html).to include("data:image/png;base64,", "copyExternalImageToTexture", "binding: 2 + index * 2")
    end
  end
end
