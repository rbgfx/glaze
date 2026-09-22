# frozen_string_literal: true

Glaze.shader :textured do
  params { texture :noise, file: "noise.png" }
  fragment do |frag_coord, resolution, u|
    texture(u.noise, frag_coord / resolution).xyz
  end
end
