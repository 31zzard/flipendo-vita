// SurrealWidgets resource loading for the Vita, used instead of resourcedata_unix.cpp (that one asks GNOME/GTK
// for the UI font through gio and fontconfig, neither of which exists on a Vita).
//
// Fonts and resource files are plain files in the game's folder on the memory card:
//   ux0:data/flipendo/fonts/NotoSans-Regular.ttf      the UI font ("system" and "monospace")
//   ux0:data/flipendo/resources/...                   the engine's Resources folder (icons, theme, ...)
// The engine can replace this default loader with its own (ResourceLoader::Set).

#include "surrealwidgets/core/resourcedata.h"
#include <fstream>
#include <stdexcept>
#include <vector>
#include <string>

namespace
{
	const char* const FontFile = VITA_DATA_ROOT "/fonts/NotoSans-Regular.ttf";
	const char* const ResourceDir = VITA_DATA_ROOT "/resources/";

	std::vector<uint8_t> ReadFile(const std::string& filename)
	{
		std::ifstream file(filename, std::ios::binary | std::ios::ate);
		if (!file)
			throw std::runtime_error("Could not open: " + filename);

		std::streamsize size = file.tellg();
		file.seekg(0, std::ios::beg);

		std::vector<uint8_t> buffer(size);
		if (size > 0 && !file.read(reinterpret_cast<char*>(buffer.data()), size))
			throw std::runtime_error("Could not read: " + filename);

		return buffer;
	}

	// "ux0:..." and "/..." are full paths, anything else is relative to the resources folder
	std::string ResolveResource(const std::string& name)
	{
		if (name.find(':') != std::string::npos || (!name.empty() && name[0] == '/'))
			return name;
		return std::string(ResourceDir) + name;
	}

	std::vector<SingleFontData> LoadUIFont()
	{
		SingleFontData fontdata;
		fontdata.fontdata = ReadFile(FontFile);
		return { std::move(fontdata) };
	}
}

std::vector<SingleFontData> ResourceData::LoadSystemFont()
{
	return LoadUIFont();
}

std::vector<SingleFontData> ResourceData::LoadMonospaceSystemFont()
{
	return LoadUIFont();
}

double ResourceData::GetSystemFontSize()
{
	return 11.0;
}

class ResourceLoaderVita : public ResourceLoader
{
public:
	std::vector<SingleFontData> LoadFont(const std::string& name) override
	{
		if (name == "system" || name == "monospace")
			return LoadUIFont();
		return { SingleFontData{ ReadFile(ResolveResource(name + ".ttf")), "" } };
	}

	std::vector<uint8_t> ReadAllBytes(const std::string& filename) override
	{
		return ReadFile(ResolveResource(filename));
	}
};

static std::unique_ptr<ResourceLoader>& GetLoader()
{
	static std::unique_ptr<ResourceLoader> loader = std::make_unique<ResourceLoaderVita>();
	return loader;
}

ResourceLoader* ResourceLoader::Get()
{
	return GetLoader().get();
}

void ResourceLoader::Set(std::unique_ptr<ResourceLoader> instance)
{
	GetLoader() = std::move(instance);
}
