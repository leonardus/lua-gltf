local gltf = {}
gltf.componentTypes = {               -- (little endian)
	[5120] = {size = 1, fmt = "<b"},  -- signed byte
	[5121] = {size = 1, fmt = "<B"},  -- unsigned byte
	[5122] = {size = 2, fmt = "<i2"}, -- signed short
	[5123] = {size = 2, fmt = "<I2"}, -- unsigned short
	[5125] = {size = 4, fmt = "<I4"}, -- unsigned int
	[5126] = {size = 4, fmt = "<f"},  -- float
}

local json = require("cjson")
local base64 = require("base64")

local function unescapePercent(str)
	return (str:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

local URI_MEDIATYPES = {
	"data:application/octet-stream;base64,",
	"data:application/gltf-buffer;base64,",
	"data:image/png;base64,",
	"data:image/jpeg;base64,"
}
local function resolveURI(uri, basePath)
	-- https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/Data_URLs
	if uri:sub(1, 5) == "data:" then
		local b64offset
		for _, h in pairs(URI_MEDIATYPES) do
			if uri:sub(1, h:len()) == h then
				b64offset = h:len() + 1
			end
		end
		if b64offset == nil then
			error("illegal mediatype")
			--[[ "When data: URI is used for buffer storage, its
			mediatype field MUST be set to application/octet-stream
			or application/gltf-buffer." ]]
		end
		return base64.decode(uri:sub(b64offset))
	end

	-- URI ABNF: https://datatracker.ietf.org/doc/html/rfc3986#appendix-A
	uri = unescapePercent(uri)
	local nzncend = (uri:find("/")) or 0
	local firstcolon = (uri:find(":")) or 0
	if firstcolon < nzncend or nzncend == 1 or uri:len() == 0 then
		error("expected data URI or relative path")
	end
	local file = io.open(basePath .. uri, "rb")
	local data = file:read("*a")
	file:close()
	return data
end

local function getBufferData(buffer)
	if buffer == nil then
		error("expected buffer (buffer:get())")
	end

	local assetMeta = getmetatable(getmetatable(buffer).asset)
	if buffer.uri == nil and assetMeta.bin then -- GLB stored buffer
		return assetMeta.bin
	end
	local data = resolveURI(buffer.uri, assetMeta.basePath)
	assert(data:len() == buffer.byteLength)
	return data
end

local function getBufferViewData(bufferView)
	if bufferView == nil then
		error("expected bufferView (bufferView:get())")
	end

	local offset = bufferView.byteOffset
	local length = bufferView.byteLength
	local buffer = bufferView.buffer:get()
	return buffer:sub(offset + 1, offset + length)
end

local function bufferUnpack(bin, accessorType, componentType, count, stride)
	local elements = {}
	local fmt = gltf.componentTypes[componentType].fmt
	local numComponents = ({SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT2 = 4, MAT3 = 9, MAT4 = 16})[accessorType]
	local componentSize = gltf.componentTypes[componentType].size
	local elemSize = numComponents*componentSize
	stride = stride or elemSize

	for i = 0, count - 1 do
		if accessorType == "SCALAR" then
			table.insert(elements, (string.unpack(fmt, bin, i*componentSize + 1)))
		elseif accessorType == "VEC2" or accessorType == "VEC3" or accessorType == "VEC4" then
			local vec = {}
			for j = 1, numComponents do
				vec[j] = string.unpack(fmt, bin, i*stride + (j - 1)*componentSize + 1)
			end
			table.insert(elements, vec)
		elseif accessorType == "MAT2" or accessorType == "MAT3" or accessorType == "MAT4" then
			local mat = {}
			for j = 0, numComponents - 1 do
				table.insert(
					mat,
					(string.unpack(fmt, bin, i*elemSize + j*componentSize + 1))
				)
			end
			table.insert(elements, mat)
		else
			error("invalid accessor type \"" .. accessorType .. "\"")
		end
	end

	return elements
end

local function getAccessorData(accessor, packed)
	packed = packed or false
	if accessor == nil then
		error("expected accessor (accessor:get())")
	end

	local numComponents = ({SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT2 = 4, MAT3 = 9, MAT4 = 16})[accessor.type]
	local elemSize = numComponents*gltf.componentTypes[accessor.componentType].size

	local bin
	if accessor.bufferView == nil then
		bin = string.rep(
			'\0',
			elemSize*accessor.count
		)
	else
		bin = accessor.bufferView:get():sub(accessor.byteOffset + 1)
	end

	if accessor.sparse then
		assert(accessor.sparse.count <= accessor.count)
		assert(accessor.sparse.indices.target == nil)
		assert(accessor.sparse.indices.byteStride == nil)
		assert(accessor.sparse.values.target == nil)
		assert(accessor.sparse.values.byteStride == nil)
		local indices = bufferUnpack(
			accessor.sparse.indices.bufferView:get():sub(accessor.sparse.indices.byteOffset + 1),
			"SCALAR",
			accessor.sparse.indices.componentType,
			accessor.sparse.count
		)
		local valuesPacked = accessor.sparse.values.bufferView:get():sub(accessor.sparse.values.byteOffset + 1)

		local map = {}
		for i1, i2 in pairs(indices) do
			map[i2] = valuesPacked:sub((i1 - 1)*elemSize + 1, i1*elemSize)
		end

		local _bin = {}
		for i = 0, accessor.count - 1 do
			table.insert(_bin, map[i] or bin:sub(i*elemSize + 1, (i + 1)*elemSize))
		end
		bin = table.concat(_bin)
	end

	if packed == true then
		return bin
	end

	return bufferUnpack(
		bin,
		accessor.type,
		accessor.componentType,
		accessor.count,
		accessor.bufferView.byteStride
	)
end

local function getImageData(image)
	if image == nil then
		error("expected image (image:get())")
	end

	if image.uri then
		assert(image.bufferView == nil)
		return resolveURI(image.uri, getmetatable(getmetatable(image).asset).basePath)
	elseif image.bufferView then
		assert(image.mimeType ~= nil)
		return image.bufferView:get()
	end
	error()
end

function gltf.new(path)
	local handle = io.open(path, "rb")
	local file = handle:read("*a")
	handle:close()

	local asset, bin
	if file:sub(1, 4) == "glTF" then
		assert(string.unpack("<I4", file, 5) == 2, "incompatible glTF verison") -- version
		assert(string.unpack("<I4", file, 9) == file:len()) -- length
		local GLTF_HEADER_SZ = 12
		local CHUNK_HEADER_SZ = 8
		assert(file:len() >= GLTF_HEADER_SZ + CHUNK_HEADER_SZ)

		local head = GLTF_HEADER_SZ + 1
		while head < file:len() do
			local chunkLength = string.unpack("<I4", file:sub(head, head + 3))
			local chunkType = file:sub(head + 4, head + 7)
			local chunkData
			if chunkLength ~= 0 then
				chunkData = file:sub(head + CHUNK_HEADER_SZ, head + CHUNK_HEADER_SZ + chunkLength - 1)
			else
				chunkData = ""
			end
			if chunkType == "JSON" then
				asset = json.decode(chunkData)
			elseif chunkType == "BIN\0" then
				bin = chunkData
			end
			head = head + CHUNK_HEADER_SZ + chunkLength
		end
	else
		asset = json.decode(file)
	end
	assert(asset.asset.version:sub(1, 1) == "2", "incompatible glTF version")
	setmetatable(asset, {bin = bin, basePath = path:sub(1, path:find("[/\\][^/\\]*$") or 0)})

	local meta = {}
	meta.swizzle = {__index = function(t, k)
		local vec_out = {}
		for i = 1, k:len() do
			local component = k:sub(i, i):lower()
			if component == "x" or component == "u" then
				table.insert(vec_out, t[1])
			elseif component == "y" or component == "v" then
				table.insert(vec_out, t[2])
			elseif component == "z" then
				if t[3] == nil then return nil end
				table.insert(vec_out, t[3])
			elseif component == "w" then
				if t[4] == nil then return nil end
				table.insert(vec_out, t[4])
			else
				return nil
			end
		end
		if #vec_out == 1 then
			return vec_out[1]
		else
			setmetatable(vec_out, meta.swizzle)
			return vec_out
		end
	end}
	meta.sampler = {__index = {
		wrapS = 10497,
		wrapT = 10497
	}}
	meta.animSampler = {__index = {interpolation = "LINEAR"}}
	meta.buffer = {
		__index = {get = getBufferData},
		asset = asset
	}
	meta.bufferView = {__index = {
		get = getBufferViewData,
		byteOffset = 0
	}}
	meta.accessor = {__index = {
		get = getAccessorData,
		byteOffset = 0,
		normalized = false
	}}
	meta.sparse = {__index = {byteOffset = 0}}
	meta.image = {
		__index = {get = getImageData},
		asset = asset
	}
	meta.pbrMetallicRoughness = {__index = {
		baseColorFactor = {1, 1, 1, 1},
		metallicFactor = 1,
		roughnessFactor = 1
	}}
	meta.normalTexture = {__index = {
		texCoord = 0,
		scale = 1
	}}
	meta.occlusionTexture = {__index = {
		texCoord = 0,
		strength = 1
	}}
	meta.emissiveTexture = {__index = {texCoord = 0}}
	meta.material = {__index = {
		emissiveFactor = {0, 0 ,0},
		alphaMode = "OPAQUE",
		alphaCutoff = 0.5,
		doubleSided = false
	}}
	meta.primitive = {__index = {
		material = (function()
			local defaultMaterial = {}
			setmetatable(defaultMaterial, meta.material)
			return defaultMaterial
		end)(),
		mode = 4
	}}
	meta.node_sqt = {__index = {
		scale = {1, 1, 1},
		rotation = {0, 0, 0, 1},
		translation = {0, 0, 0}
	}}
	setmetatable(meta.node_sqt.__index.scale, meta.swizzle)
	setmetatable(meta.node_sqt.__index.rotation, meta.swizzle)
	setmetatable(meta.node_sqt.__index.translation, meta.swizzle)

	for _, scene in pairs(asset.scenes or {}) do
		for i, node in pairs(scene.nodes) do
			scene.nodes[i] = asset.nodes[node + 1]
		end
	end
	asset.scene = asset.scene and asset.scenes[asset.scene + 1] or nil

	for _, sampler in pairs(asset.samplers or {}) do
		setmetatable(sampler, meta.sampler)
	end

	for _, skin in pairs(asset.skins or {}) do
		skin.inverseBindMatrices = skin.inverseBindMatrices and asset.accessors[skin.inverseBindMatrices + 1] or nil
		skin.skeleton = skin.skeleton and asset.nodes[skin.skeleton + 1] or nil
		for i, v in pairs(skin.joints) do
			skin.joints[i] = asset.nodes[v + 1]
		end
	end

	for _, animation in pairs(asset.animations or {}) do
		for _, channel in pairs(animation.channels) do
			channel.sampler = animation.samplers[channel.sampler + 1]
			channel.target.node = channel.target.node and asset.nodes[channel.target.node + 1] or nil
		end
		for _, sampler in pairs(animation.samplers) do
			sampler.input = asset.accessors[sampler.input + 1]
			sampler.output = asset.accessors[sampler.output + 1]
			setmetatable(sampler, meta.animSampler)
		end
	end

	for _, buffer in pairs(asset.buffers or {}) do
		setmetatable(buffer, meta.buffer)
	end

	for _, bufferView in pairs(asset.bufferViews or {}) do
		bufferView.buffer = asset.buffers[bufferView.buffer + 1]
		setmetatable(bufferView, meta.bufferView)
	end

	for _, accessor in pairs(asset.accessors or {}) do
		accessor.bufferView = accessor.bufferView and asset.bufferViews[accessor.bufferView + 1] or nil
		setmetatable(accessor, meta.accessor)
		if accessor.sparse then
			accessor.sparse.indices.bufferView = asset.bufferViews[accessor.sparse.indices.bufferView + 1]
			accessor.sparse.values.bufferView = asset.bufferViews[accessor.sparse.values.bufferView + 1]
			setmetatable(accessor.sparse.indices, meta.sparse)
			setmetatable(accessor.sparse.values, meta.sparse)
		end
	end

	for _, image in pairs(asset.images or {}) do
		image.bufferView = image.bufferView and asset.bufferViews[image.bufferView + 1] or nil
		setmetatable(image, meta.image)
	end

	for _, texture in pairs(asset.textures or {}) do
		if texture.sampler then
			texture.sampler = asset.samplers[texture.sampler + 1] --[[ TODO:
			"When undefined, a sampler with repeat wrapping and auto filtering
			SHOULD be used." ]]
		end
		if texture.source then
			texture.source = asset.images[texture.source + 1] --[[ TODO:
			"When undefined, an extension or other mechanism SHOULD supply
			an alternate texture source, otherwise behavior is undefined." ]]
		end
	end

	for _, material in pairs(asset.materials or {}) do
		local pbrmr = material.pbrMetallicRoughness
		if pbrmr then
			if pbrmr.baseColorTexture then
				pbrmr.baseColorTexture.texture = asset.textures[pbrmr.baseColorTexture.index + 1]
				pbrmr.baseColorTexture.index = nil
			end
			if pbrmr.metallicRoughnessTexture then
				pbrmr.metallicRoughnessTexture.texture = asset.textures[pbrmr.metallicRoughnessTexture.index + 1]
				pbrmr.metallicRoughnessTexture.index = nil
			end
			setmetatable(material.pbrMetallicRoughness, meta.pbrMetallicRoughness)
		end

		if material.normalTexture then
			material.normalTexture.texture = asset.textures[material.normalTexture.index + 1]
			material.normalTexture.index = nil
			setmetatable(material.normalTexture, meta.normalTexture)
		end

		if material.occlusionTexture then
			material.occlusionTexture.texture = asset.textures[material.occlusionTexture.index + 1]
			material.occlusionTexture.index = nil
			setmetatable(material.occlusionTexture, meta.occlusionTexture)
		end

		if material.emissiveTexture then
			material.emissiveTexture.texture = asset.textures[material.emissiveTexture.index + 1]
			material.emissiveTexture.index = nil
			setmetatable(material.emissiveTexture, meta.emissiveTexture)
		end

		setmetatable(material, meta.material)
	end

	local meshes = asset.meshes
	for _, mesh in pairs(meshes or {}) do
		for _, primitive in pairs(mesh.primitives) do
			for k, v in pairs(primitive.attributes) do
				primitive.attributes[k] = asset.accessors[v + 1]
			end
			primitive.indices = primitive.indices and asset.accessors[primitive.indices + 1] or nil
			primitive.material = primitive.material and asset.materials[primitive.material + 1] or nil
			setmetatable(primitive, meta.primitive)
		end
	end

	local nodes = asset.nodes
	for _, node in pairs(nodes or {}) do
		node.mesh = node.mesh and meshes[node.mesh + 1] or nil
		local children = {}
		for _, index in pairs(node.children or {}) do
			table.insert(children, nodes[index + 1])
			assert(nodes[index + 1].parent == nil  or nodes[index + 1].parent == node)
			nodes[index + 1].parent = node
		end
		node.children = node.children and children or nil

		setmetatable(node.scale or {}, meta.swizzle)
		setmetatable(node.rotation or {}, meta.swizzle)
		setmetatable(node.translation or {}, meta.swizzle)

		if node.matrix == nil then
			setmetatable(node, meta.node_sqt)
		end
	end

	return asset
end

return gltf
