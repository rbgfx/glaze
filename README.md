# Glaze

[![Gem version](https://badge.fury.io/rb/glaze.svg)](https://rubygems.org/gems/glaze)
[![Downloads](https://img.shields.io/gem/dt/glaze?label=downloads)](https://rubygems.org/gems/glaze)
[![CI](https://github.com/rbgfx/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/rbgfx/glaze/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-MIT-750014.svg)](LICENSE.txt)

> Live shader coding for Ruby, from a saved file to a window, PNG, or WebGPU page.

Glaze loads shader definitions written in Ruby, compiles them through rlsl, and
renders them with rbgl. It supports live reload, headless output, parameter
metadata, and WebGPU export.

**[Features](#features) · [Installation](#installation) · [Quick start](#quick-start) · [Shader files](#shader-files) · [Development](#development)**

## Features

- Live reload for shader files without losing the current frame on a bad edit.
- CPU rendering for portable and headless workflows.
- Metal rendering and GPU pixel capture on supported macOS hosts.
- PNG screenshots, frame sequences, and standalone WebGPU HTML export.
- Typed parameters with defaults, ranges, steps, and an optional Twiddle panel.
- Built-in uniforms for time, frame, mouse, resolution, and fragment position.

## Installation

Add Glaze to your Gemfile:

~~~ruby
gem "glaze"
~~~

Then run:

~~~sh
bundle install
~~~

Or install the released gem:

~~~sh
gem install glaze
~~~

The CPU renderer and screenshot commands require a C compiler. Metal rendering
is available on macOS with a Metal-capable device.

## Quick start

Run the included examples:

~~~sh
glaze run examples/plasma.rb
glaze shot examples/plasma.rb --time 1.5 --size 640x360 -o shot.png
glaze record examples/plasma.rb --seconds 2 --fps 30 -o frames
glaze export examples/plasma.rb plasma.html
~~~

Run a fixed number of headless CPU frames:

~~~sh
glaze run examples/plasma.rb --renderer cpu --backend file --frames 2 --output-dir frames
~~~

## Shader files

A shader file contains one <code>Glaze.shader</code> definition:

~~~ruby
Glaze.shader(:gradient) do
  params do
    float :speed, default: 1.0, range: 0.0..4.0
  end

  fragment do |point, resolution, uniforms|
    value = point[0] / resolution[0] + uniforms.time * uniforms.speed
    [value % 1.0, 0.2, 0.4, 1.0]
  end
end
~~~

Fragments use rlsl syntax. Texture parameters are supported by the Metal
runner; the WebGPU exporter embeds the referenced PNG bytes in its HTML.

## Development

~~~sh
bundle install
bundle exec rake verify
~~~

## License

[MIT](LICENSE.txt)
