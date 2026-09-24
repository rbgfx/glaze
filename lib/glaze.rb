# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "cgi"
require "ripper"
require "tessel"

require_relative "glaze/version"

module Glaze
  class Error < StandardError; end
  BUILT_INS = %i[time frame mouse resolution frag_coord u].freeze
  TYPE_SIZES = { float: [4, 4], int: [4, 4], bool: [4, 4], vec2: [8, 8], vec3: [12, 16], vec4: [16, 16] }.freeze

  Param = Struct.new(:name, :type, :default, :range, :step, :file, keyword_init: true)

  class ParamsContext
    attr_reader :params

    def initialize
      @params = []
    end

    TYPE_SIZES.keys.each do |type|
      define_method(type) do |name, default: nil, range: nil, step: nil|
        name = name.to_sym
        raise ArgumentError, "uniform name is reserved: #{name}" if BUILT_INS.include?(name)
        raise ArgumentError, "duplicate uniform: #{name}" if @params.any? { |param| param.name == name }
        default = default_for(type, default)
        validate(type, default, range, step)
        @params << Param.new(name: name, type: type, default: default, range: range, step: step)
      end
    end

    def texture(name, file:)
      name = name.to_sym
      raise ArgumentError, "uniform name is reserved: #{name}" if BUILT_INS.include?(name)
      raise ArgumentError, "duplicate uniform: #{name}" if @params.any? { |param| param.name == name }
      raise ArgumentError, "texture file is required" if file.to_s.empty?
      @params << Param.new(name: name, type: :sampler2D, file: file.to_s)
    end

    def uniforms(&block)
      params(&block)
    end

    private

    def default_for(type, value)
      return value unless value.nil?
      type == :bool ? false : type == :int ? 0 : type.to_s.start_with?("vec") ? Array.new(type.to_s.delete_prefix("vec").to_i, 0.0) : 0.0
    end

    def validate(type, default, range, step)
      case type
      when :float
        raise TypeError, "float uniform default must be numeric" unless default.is_a?(Numeric)
      when :int
        raise TypeError, "int uniform default must be an integer" unless default.is_a?(Integer)
      when :bool
        raise TypeError, "bool uniform default must be true or false" unless [true, false].include?(default)
      else
        size = type.to_s.delete_prefix("vec").to_i
        raise TypeError, "vector uniform default must be an array" unless default.is_a?(Array)
        raise ArgumentError, "vector uniform default has the wrong length" unless default.length == size
        raise TypeError, "vector uniform default must be numeric" unless default.all? { |value| value.is_a?(Numeric) }
      end
      if range
        raise ArgumentError, "uniform range is only valid for numeric uniforms" unless %i[float int].include?(type)
        raise TypeError, "uniform range must be a Range" unless range.is_a?(Range)
        raise TypeError, "uniform range endpoints must be numeric" unless range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)
        raise ArgumentError, "uniform range must increase" unless range.begin < range.end
        raise ArgumentError, "uniform range must be finite" unless range.begin.to_f.finite? && range.end.to_f.finite?
        raise ArgumentError, "uniform default is outside its range" unless range.cover?(default)
      end
      if step
        raise ArgumentError, "uniform step is only valid for numeric uniforms" unless %i[float int].include?(type)
        raise TypeError, "uniform step must be numeric" unless step.is_a?(Numeric)
        raise ArgumentError, "uniform step must be positive and finite" unless step.positive? && step.to_f.finite?
        raise TypeError, "int uniform step must be an integer" if type == :int && !step.is_a?(Integer)
      end
    end
  end

  class Definition
    attr_reader :name, :params, :fragment_block, :helper_blocks, :function_blocks, :source

    def initialize(name)
      @name = name.to_sym
      @params = []
      @helper_blocks = []
      @function_blocks = []
    end

    def params(&block)
      return @params unless block

      context = ParamsContext.new
      context.instance_eval(&block)
      duplicate = context.params.find { |param| @params.any? { |existing| existing.name == param.name } }
      raise ArgumentError, "duplicate uniform: #{duplicate.name}" if duplicate
      @params.concat(context.params)
    end

    alias uniforms params

    def fragment(&block)
      @fragment_block = block
      @source = block&.source_location
    end

    def helpers(&block) = @helper_blocks << block
    def functions(&block) = @function_blocks << block

    def param(name)
      @params.find { |param| param.name == name.to_sym }
    end

    def rlsl_builder
      require "rlsl"
      definition = self
      builder = RLSL::ShaderBuilder.new(@name)
      builder.uniforms do
        float :time
        int :frame
        vec4 :mouse
        definition.params.each { |param| public_send(param.type, param.name) }
      end
      @function_blocks.each { |block| builder.functions(&block) }
      @helper_blocks.each { |block| builder.helpers(&block) }
      raise Error, "shader #{@name} has no fragment" unless @fragment_block
      builder.fragment(&@fragment_block)
      builder
    end
  end

  class Loader
    Result = Struct.new(:definition, :error, :location, keyword_init: true) do
      def ok? = !definition.nil? && error.nil?
    end

    def load(path)
      Result.new(definition: Glaze.load_file(path))
    rescue SyntaxError, StandardError => e
      Result.new(error: e, location: e.backtrace&.first)
    end
  end

  module Runners
    class ParamPanel
      attr_reader :ui

      def initialize(definition)
        require "twiddle"
        @definition = definition
        @ui = Twiddle::Context.new
      end

      def render(image, events:, values:)
        @ui.frame(events: events) do |ui|
          ui.window("Parameters") do
            @definition.params.each do |param|
              if param.range && %i[float int].include?(param.type)
                maximum = param.range.exclude_end? ? param.range.end - (param.type == :int ? 1 : Float::EPSILON) : param.range.end
                values[param.name] = ui.slider(param.name.to_s, values[param.name], param.range.begin..maximum)
              else
                ui.label("#{param.name}: #{values[param.name].inspect}")
              end
            end
          end
        end
        @ui.render(image)
      end
    end

    class CPU
      attr_reader :definition

      def initialize(definition)
        raise Error, "texture params require the Metal runner" if definition.params.any? { |param| param.type == :sampler2D }
        @definition = definition
        @shader = definition.rlsl_builder.compile_and_load
      end

      def render(width:, height:, time: 0.0, frame: 0, mouse: [0.0, 0.0, 0.0, 0.0], params: {})
        buffer = "\0".b * (width * height * 4)
        uniforms = @definition.params.to_h { |param| [param.name, params.fetch(param.name, param.default)] }
        @shader.render(buffer, width, height, uniforms.merge(time: time, frame: frame, mouse: mouse))
        # rlsl's C renderer writes top-down BGRA; Tessel uses top-down RGBA.
        rgba = buffer.unpack("L<*").map { |pixel| (pixel & 0xff00_ff00) | ((pixel & 0xff) << 16) | ((pixel >> 16) & 0xff) }.pack("L<*")
        Tessel::Image.from_rgba(width, height, rgba)
      end
    end

    class Metal
      attr_reader :definition

      def initialize(definition, handle)
        @definition = definition
        @handle = handle
        @textures = {}
        begin
          base = File.dirname(File.expand_path(definition.instance_variable_get(:@file) || "."))
          definition.params.each do |param|
            next unless param.type == :sampler2D
            image = Tessel.read(File.expand_path(param.file, base))
            @textures[param.name] = Metaco.texture_create(handle, image.width, image.height, image.bytes)
          end
          @shader = definition.rlsl_builder.build_metal_shader
          @shader.prepare(handle)
        rescue Exception
          close
          raise
        end
      end

      def render(width:, height:, time: 0.0, frame: 0, mouse: [0.0, 0.0, 0.0, 0.0], params: {})
        uniforms = @definition.params.reject { |param| param.type == :sampler2D }.to_h { |param| [param.name, params.fetch(param.name, param.default)] }
        @shader.render_metal(@handle, width, height, uniforms.merge(time: time, frame: frame, mouse: mouse), textures: @textures)
      end

      def read_image(width, height)
        Tessel::Image.from_rgba(width, height, Metaco.read_pixels(@handle))
      end

      def close
        @textures.each_value { |texture| Metaco.texture_destroy(texture) }
        @textures.clear
      end
    end

    class Window
      def initialize(path, width:, height:, backend: :auto, renderer: :auto, fps: 60, frames: nil, output_dir: ".", panel: false)
        requested_backend = backend.to_sym
        @renderer = renderer.to_sym
        if @renderer == :auto && %i[cpu metal].include?(requested_backend)
          @renderer = requested_backend
          requested_backend = requested_backend == :metal ? :cocoa : :auto
        end
        @path, @width, @height, @backend, @fps, @frames, @output_dir, @panel = path, width, height, requested_backend, fps, frames, output_dir, panel
        raise ArgumentError, "unknown RBGL backend: #{@backend}" unless %i[auto file cocoa x11 wayland].include?(@backend)
        raise ArgumentError, "renderer must be :auto, :cpu, or :metal" unless %i[auto cpu metal].include?(@renderer)
        raise ArgumentError, "fps must be positive" unless @fps.positive?
      end

      def run
        require "rbgl"
        loaded = Loader.new.load(@path)
        raise loaded.error unless loaded.ok?
        params = ParamState.new(loaded.definition)
        watcher = Watcher.new(@path)
        watcher.changed?
        options = @backend == :file ? { format: :ppm, output_dir: @output_dir, max_frames: @frames || 1 } : {}
        window = RBGL::GUI::Window.new(width: @width, height: @height, title: "glaze: #{loaded.definition.name}", backend: @backend, **options)
        metal = @renderer == :metal || (@renderer == :auto && window.metal_available?)
        raise LoadError, "Metal backend is unavailable" if metal && !window.metal_available?
        renderer = metal ? Metal : CPU
        runner = renderer == Metal ? Metal.new(loaded.definition, window.native_handle) : CPU.new(loaded.definition)
        panel = @panel && renderer == CPU ? ParamPanel.new(loaded.definition) : nil
        input = InputState.new(width: @width, height: @height)
        clock = Clock.new
        show_hud = true
        reload_error = nil
        until window.should_close?
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          save_shot = false
          events = Array(window.poll_events_raw)
          events.each do |event|
            case event[:type]
            when :mouse_move then input.mouse_move(event[:x], event[:y])
            when :mouse_press then input.mouse_press(event[:x], event[:y])
            when :mouse_release then input.mouse_release(event[:x], event[:y])
            when :key_press
              key = event[:key]
              key = key.to_sym if key.respond_to?(:to_sym)
              save_shot = true if key == :s || event[:char] == "s"
              clock.paused? ? clock.resume : clock.pause if key == :space
              clock.reset if key == :r
              show_hud = !show_hud if key == :h || event[:char] == "h"
              params.select(params.selected + 1) if %i[tab down].include?(key)
              params.select(params.selected - 1) if key == :up
              params.adjust(1) if key == :right
              params.adjust(-1) if key == :left
            when :resize
              @width, @height = event[:width], event[:height]
              input = InputState.new(width: @width, height: @height)
            end
          end
          if watcher.changed?
            candidate = Loader.new.load(@path)
            begin
              raise candidate.error unless candidate.ok?
              next_runner = renderer == Metal ? Metal.new(candidate.definition, window.native_handle) : CPU.new(candidate.definition)
              previous_runner = runner
              runner = next_runner
              previous_runner.close if previous_runner.is_a?(Metal)
              params = ParamState.new(candidate.definition)
              panel = ParamPanel.new(candidate.definition) if panel
              reload_error = nil
              warn "reloaded #{@path}"
            rescue StandardError => e
              reload_error = e.message
              warn "reload failed: #{e.message}"
            end
          end
          clock.tick
          image = runner.render(width: @width, height: @height, time: clock.time, frame: clock.frame, mouse: input.mouse, params: params.values)
          draw_hud(image, runner.definition, params, reload_error) if show_hud && image
          panel&.render(image, events: events, values: params.values)
          window.set_pixels(image.bytes) if image
          if save_shot
            FileUtils.mkdir_p("shots")
            destination = File.join("shots", "#{runner.definition.name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.png")
            if runner.is_a?(Metal)
              Glaze.save_capture(runner.read_image(@width, @height), runner.definition, destination, params: params.values)
            else
              Glaze.capture(runner.definition, destination, time: clock.time, params: params.values, size: [@width, @height])
            end
          end
          delay = 1.0 / @fps - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          sleep(delay) if delay.positive? && @backend != :file
        end
      ensure
        runner.close if runner.is_a?(Metal)
        window&.close
      end

      private

      def draw_hud(image, definition, params, reload_error)
        require "glyphic"
        parameter = definition.params[params.selected]
        text = if reload_error
          "reload failed: #{reload_error}"
        elsif parameter
          "#{parameter.name}: #{params.values[parameter.name].inspect}"
        end
        return unless text

        image.fill_rect(0, 0, image.width, [20, image.height].min, [0, 0, 0, 190], blend: :alpha)
        Glyphic.default.draw(image, 4, 3, text.slice(0, [image.width / 6, 1].max), color: [255, 255, 255, 255])
      rescue LoadError
        nil
      end
    end
  end

  class Clock
    attr_reader :time, :frame

    def initialize(clock: Process.method(:clock_gettime))
      @clock = clock
      @started = now
      @time = 0.0
      @frame = 0
      @paused = false
    end

    def tick
      @time = now - @started unless @paused
      @frame += 1
      self
    end

    def pause = (@paused = true)
    def resume = (@started = now - @time; @paused = false)
    def paused? = @paused
    def reset = (@started = now; @time = 0.0; @frame = 0)
    def seek(seconds) = (@started = now - seconds.to_f; @time = seconds.to_f)

    private

    def now
      @clock.call(Process::CLOCK_MONOTONIC)
    end
  end

  class InputState
    attr_reader :mouse, :keys

    def initialize(width: 1, height: 1)
      @width = width
      @height = height
      @mouse = [0.0, 0.0, 0.0, 0.0]
      @keys = {}
    end

    def mouse_move(x, y)
      @mouse[0] = x
      @mouse[1] = @height - 1 - y
    end

    def mouse_press(x, y)
      mouse_move(x, y)
      @mouse[2] = @mouse[0]
      @mouse[3] = @mouse[1]
    end

    def mouse_release(x, y)
      mouse_move(x, y)
      @mouse[2] = -@mouse[2].abs
      @mouse[3] = -@mouse[3].abs
    end

    def key(key, down: true)
      @keys[key.to_sym] = down
    end
  end

  class ParamState
    attr_reader :values, :selected

    def initialize(definition)
      @values = definition.params.to_h { |param| [param.name, param.default] }
      @params = definition.params
      @selected = 0
    end

    def select(index)
      @selected = @params.empty? ? 0 : [[index.to_i, 0].max, @params.length - 1].min
    end

    def adjust(amount)
      param = @params[@selected]
      return unless param && %i[float int].include?(param.type)
      step = param.step || (param.type == :int ? 1 : 0.01)
      value = @values[param.name] + amount.to_f * step
      if param.range
        maximum = param.range.exclude_end? ? param.range.end - (param.type == :int ? 1 : Float::EPSILON) : param.range.end
        value = [[value, param.range.begin].max, maximum].min
      end
      @values[param.name] = param.type == :int ? value.round : value
    end
  end

  class Watcher
    def initialize(path)
      @path = path
      @signature = nil
    end

    def changed?
      signature = normalized_signature
      changed = signature != @signature
      @signature = signature
      changed
    rescue Errno::ENOENT
      false
    end

    private

    def normalized_signature
      tokens = Ripper.lex(File.read(@path)).reject { |(_, type, _, _)| %i[on_sp on_nl on_ignored_nl on_comment].include?(type) }
      Digest::SHA256.hexdigest(tokens.map { |(_, type, text, _)| "#{type}:#{text}" }.join)
    rescue SyntaxError, EncodingError
      Digest::SHA256.file(@path).hexdigest
    end
  end

  module Export
    module UniformLayout
      module_function

      def build(params)
        offset = 0
        result = {}
        params.each do |param|
          size, alignment = TYPE_SIZES.fetch(param.type)
          offset = align(offset, alignment)
          result[param.name] = { offset: offset, type: param.type }
          offset += size
        end
        { fields: result, size: align(offset, 16) }
      end

      def align(value, alignment)
        (value + alignment - 1) / alignment * alignment
      end
      private_class_method :align
    end

    module WebGPU
      module_function

      def write(definition, path)
        value_params = definition.params.reject { |param| param.type == :sampler2D }
        texture_params = definition.params.select { |param| param.type == :sampler2D }
        base = File.dirname(File.expand_path(definition.instance_variable_get(:@file) || "."))
        images = texture_params.map do |param|
          image = Tessel.read(File.expand_path(param.file, base))
          { name: param.name, data: "data:image/png;base64,#{[Tessel::PNG.encode(image)].pack('m0')}" }
        end
        layout = UniformLayout.build([
          Param.new(name: :resolution, type: :vec2),
          Param.new(name: :time, type: :float),
          Param.new(name: :frame, type: :int),
          Param.new(name: :mouse, type: :vec4),
          *value_params
        ])
        source = definition.rlsl_builder.build_wgsl_shader
        params = value_params.map do |param|
          { name: param.name, type: param.type, default: param.default,
            range: param.range && [param.range.begin, param.range.end], exclude_end: param.range&.exclude_end?, step: param.step }
        end
        script_json = ->(value) { JSON.generate(value).gsub("</", "<\\/") }
        runner = File.read(File.expand_path("glaze/webgpu_runner.js", __dir__))
        html = <<~HTML
          <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(definition.name.to_s)}</title>
          <style>html,body{margin:0;width:100%;height:100%;background:#111;color:#eee;font:14px sans-serif}canvas{width:100%;height:100%;display:block}#panel{position:fixed;top:12px;left:12px;background:#000a;padding:12px}label{display:block}</style>
          <canvas></canvas><div id="panel"><div id="status"></div><div id="params"></div></div>
          <script>#{runner}
          const shaderSource = #{script_json.call(source)};
          const layout = #{script_json.call(layout)};
          const params = #{script_json.call(params)};
          const images = #{script_json.call(images)};
          GlazeWGSL.run(document.querySelector("canvas"), shaderSource, layout, { params, images });
          </script>
        HTML
        File.write(path, html)
        path
      end
    end
  end

  module_function

  def shader(name, &block)
    definition = Definition.new(name)
    definition.instance_eval(&block) if block
    definitions << definition
    definition
  end

  def definitions
    @definitions ||= []
  end

  def load_file(path)
    definitions.clear
    File.read(path)
    load(path, true)
    raise Error, "expected one Glaze.shader in #{path}, found #{definitions.length}" unless definitions.length == 1
    definitions.first.tap { |definition| definition.instance_variable_set(:@file, path) }
  rescue SyntaxError, StandardError => e
    raise Error, "#{path}: #{e.message}"
  end

  def render(definition, width:, height:, time: 0.0, params: {})
    image = Tessel::Image.new(width, height)
    return image unless definition.fragment_block
    uniforms = definition.params.to_h { |param| [param.name, params.fetch(param.name, param.default)] }
    (0...height).each do |y|
      (0...width).each do |x|
        value = definition.fragment_block.call([x + 0.5, y + 0.5], [width, height], uniforms.merge(time: time, resolution: [width, height], frag_coord: [x + 0.5, y + 0.5]))
        rgba = value.is_a?(Array) ? value : [value, value, value, 1.0]
        rgba = rgba.first(4).map { |channel| [[(channel.to_f <= 1 ? channel.to_f * 255 : channel.to_f).round, 0].max, 255].min }
        rgba << 255 if rgba.length == 3
        image[x, y] = rgba
      end
    end
    image
  end

  def export_webgpu(definition, path)
    Export::WebGPU.write(definition, path)
  end

  def run_file(path, **options)
    Runners::Window.new(path, **options).run
  end

  def capture(definition, path, time: 0.0, params: {}, size: [640, 360])
    image = if definition.instance_variable_get(:@file)
      Runners::CPU.new(definition).render(width: size[0], height: size[1], time: time, params: params)
    else
      render(definition, width: size[0], height: size[1], time: time, params: params)
    end
    save_capture(image, definition, path, params: params)
  end

  def save_capture(image, definition, path, params: {})
    source = definition.instance_variable_get(:@file) && File.read(definition.instance_variable_get(:@file))
    image.instance_variable_get(:@metadata).merge!("glaze:source" => source.to_s, "glaze:uniforms" => JSON.generate(params), "Software" => "glaze")
    image.write(path)
  end
end
