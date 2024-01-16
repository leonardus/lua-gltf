# lua-gltf
## Usage
```lua
local gltf = require("gltf")
local myAsset = gltf.new("/path/to/file.gltf")
```
The returned object is identical to a [standard glTF object](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html) with the following differences:
 - Any fields which reference an index now reference the object itself
 - Each `node` has the field `node.parent`
 - Buffers, buffer views, accessors, and images have a `:get()` method
	 - When called on an accessor, an additional boolean argument `packed` is accepted (defaults to `false`). If `true`, the value returned will be the raw string which holds the accessor data. Otherwise, this method returns the values contained in the accessor.
