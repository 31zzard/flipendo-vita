#pragma once

// std::filesystem::copy_file on the Vita (newlib) makes the new file but copies nothing: 0 bytes (HP2's save picture Save0.bmp and
// persistent actor cache, 2026-11-06). The engine patches of apply_fixes.sh #121 copy with plain reads and writes instead.

#include <cstdio>
#include <filesystem>
#include <system_error>
#include <vector>

inline bool VitaCopyFile(const std::filesystem::path& from, const std::filesystem::path& to, std::filesystem::copy_options, std::error_code& ec)
{
	ec.clear();
	FILE* in = fopen(from.string().c_str(), "rb");
	if (!in)
	{
		ec = std::make_error_code(std::errc::no_such_file_or_directory);
		return false;
	}
	FILE* out = fopen(to.string().c_str(), "wb");
	bool ok = out != nullptr;
	std::vector<char> buffer(64 * 1024);
	size_t n;
	while (ok && (n = fread(buffer.data(), 1, buffer.size(), in)) > 0)
		ok = fwrite(buffer.data(), 1, n, out) == n;
	fclose(in);
	if (out && fclose(out) != 0)
		ok = false;
	if (!ok)
	{
		std::remove(to.string().c_str());
		ec = std::make_error_code(std::errc::io_error);
	}
	return ok;
}
