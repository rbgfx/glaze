# frozen_string_literal: true

Glaze.shader :gradient do
  fragment do |frag_coord, resolution, _u|
    uv = frag_coord / resolution
    vec3(uv.x, uv.y, 0.25)
  end
end
