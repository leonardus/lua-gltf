# lua-gltf
## Installation
Install with [luarocks](https://luarocks.org/): `$ luarocks install lua-gltf`
## Usage
```lua
local gltf = require("gltf")
local asset = gltf.new("/path/to/file.gltf")
```
The returned table is identical to a [standard glTF asset](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html) with the following differences:
 - Any fields which hold an index, now instead hold the object referenced by that index
	- To get the original numerical index, call `asset:IndexOf(object)`. Keep in mind that these values will begin from 0, as they correspond to the indices in the glTF file.
 - Each `node` has the field `node.parent`
 - Buffers, buffer views, accessors, and images have a `:get()` method
	 - When called on an accessor, an additional boolean argument `packed` is accepted (defaults to `false`). If `true`, the value returned will be the raw string which holds the accessor data. Otherwise, this method returns the values contained in the accessor.
