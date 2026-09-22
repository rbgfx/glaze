# frozen_string_literal: true

Glaze.shader :plasma do
  params { float :speed, default: 1.0, range: 0.0..4.0, step: 0.1 }

  fragment do |frag_coord, resolution, u|
    uv = frag_coord / resolution
    r = sin(u.time * u.speed + uv.x * 6.28) * 0.5 + 0.5
    g = sin(u.time * u.speed + uv.y * 6.28) * 0.5 + 0.5
    b = sin(u.time * u.speed + (uv.x + uv.y) * 6.28) * 0.5 + 0.5
    vec3(r, g, b)
  end
end
