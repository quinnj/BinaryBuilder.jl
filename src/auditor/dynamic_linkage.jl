using ObjectFile.ELF

"""
    is_for_platform(h::ObjectHandle, platform::Platform)

Returns `true` if the given `ObjectHandle` refers to an object of the given
`platform`; E.g. if the given `platform` is for AArch64 Linux, then `h` must
be an `ELFHandle` with `h.header.e_machine` set to `ELF.EM_AARCH64`.
"""
function is_for_platform(h::ObjectHandle, platform::Platform)
    if platform isa Linux
        h isa ELFHandle || return false
        (h.ei.osabi == ELF.ELFOSABI_LINUX ||
         h.ei.osabi == ELF.ELFOSABI_NONE) || return false
        mach = h.header.e_machine
        if platform.arch == :i686
            return mach == ELF.EM_386
        elseif platform.arch == :x86_64
            # Allow i686 as well, because that's technically ok
            return (
                mach == ELF.EM_386 ||
                mach == ELF.EM_X86_64)
        elseif platform.arch == :aarch64
            return mach == ELF.EM_AARCH64
        elseif platform.arch == :powerpc64le || platform.arch == :ppc64le
            return mach == ELF.EM_PPC64
        elseif platform.arch == :armv7l
            return mach == ELF.EM_ARM
        else
            error("Unknown architecture")
        end
    elseif platform isa Windows
        if platform.arch == :x86_64
            return h isa COFFHandle
        elseif platform.arch == :i686
            return h isa COFFHandle && !is64bit(h)
        else
            error("Unknown architecture")
        end
    elseif platform isa MacOS
        h isa MachOHandle || return false
        return true
    else
        error("Unkown platform")
    end
end

# These are libraries we should straight-up ignore, like libsystem on OSX
function should_ignore_lib(lib, ::ELFHandle)
    ignore_libs = [
        "libc.so.6",
        # libgcc Linux and FreeBSD style
        "libgcc_s.1.so",
        "libgcc_s.so.1",
        "libm.so.6",
        "libgfortran.so.3",
        "libgfortran.so.4",
    ]
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::MachOHandle)
    ignore_libs = [
        "libsystem.b.dylib",
    ]
    return lowercase(basename(lib)) in ignore_libs
end
function should_ignore_lib(lib, ::COFFHandle)
    ignore_libs = [
        "msvcrt.dll",
        "kernel32.dll",
        "user32.dll",
        "libgcc_s_sjlj-1.dll",
        "libgfortran-3.dll",
        "libgfortran-4.dll",
    ]
    return lowercase(basename(lib)) in ignore_libs
end

# Determine whether a library is a "default" library or not, if it is we need
# to map it to `@rpath/$libname` on OSX.
is_default_lib(lib, oh) = false
function is_default_lib(lib, ::MachOHandle)
    default_libs = [
        "libgcc_s.1.dylib",
        "libgfortran.3.dylib",
        "libgfortran.4.dylib",
        "libquadmath.0.dylib",
    ]
    return lowercase(basename(lib)) in default_libs
end

function relink_to_rpath(prefix::Prefix, platform::Platform, path::AbstractString,
                         old_libpath::AbstractString; verbose::Bool = false)
    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)
    libname = basename(old_libpath)
    relink_cmd = ``

    if Compat.Sys.isapple(platform)
        install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
        relink_cmd = `$install_name_tool -change $(old_libpath) @rpath/$(libname) $(rel_path)`
    elseif Compat.Sys.islinux(platform)
        patchelf = "/usr/local/bin/patchelf"
        relink_cmd = `$patchelf --replace-needed $(old_libpath) \$ORIGIN/$(libname) $(rel_path)`
    end

    # Create a new linkage that looks like $ORIGIN/../lib, or similar
    logpath = joinpath(logdir(prefix), "relink_to_rpath_$(basename(rel_path))_$(libname).log")
    run(ur, relink_cmd, logpath; verbose=verbose)
end

"""
    update_linkage(prefix::Prefix, platform::Platform, path::AbstractString,
                   old_libpath, new_libpath; verbose::Bool = false)

Given a binary object located at `path` within `prefix`, update its dynamic
linkage to point to `new_libpath` instead of `old_libpath`.  This is done using
a tool within the cross-compilation environment such as `install_name_tool` on
MacOS or `patchelf` on Linux.  Windows platforms are completely skipped, as
they do not encode paths or RPaths within their executables.
"""
function update_linkage(prefix::Prefix, platform::Platform, path::AbstractString,
                        old_libpath, new_libpath; verbose::Bool = false)
    # Windows doesn't do updating of linkage
    if Compat.Sys.iswindows(platform)
        return
    end

    ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)
    rel_path = relpath(path, prefix.path)

    add_rpath = x -> ``
    relink = (x, y) -> ``
    origin = ""
    patchelf = "/usr/local/bin/patchelf"
    install_name_tool = "/opt/x86_64-apple-darwin14/bin/install_name_tool"
    if Compat.Sys.isapple(platform)
        origin = "@loader_path"
        add_rpath = rp -> `$install_name_tool -add_rpath $(rp) $(rel_path)`
        relink = (op, np) -> `$install_name_tool -change $(op) $(np) $(rel_path)`
    elseif Compat.Sys.islinux(platform)
        origin = "\$ORIGIN"
        full_rpath = join(':', rpaths(RPath(readmeta(path))))
        add_rpath = rp -> `$patchelf --set-rpath $(full_rpath):$(rp) $(rel_path)`
        relink = (op, np) -> `$patchelf --replace-needed $(op) $(np) $(rel_path)`
    end

    if !(dirname(new_libpath) in canonical_rpaths(RPath(readmeta(path))))
        libname = basename(old_libpath)
        logpath = joinpath(logdir(prefix), "update_rpath_$(libname).log")
        cmd = add_rpath(relpath(dirname(new_libpath), dirname(path)))
        run(ur, cmd, logpath; verbose=verbose)
    end

    # Create a new linkage that looks like $ORIGIN/../lib, or similar
    libname = basename(old_libpath)
    logpath = joinpath(logdir(prefix), "update_linkage_$(libname).log")
    origin_relpath = joinpath(origin, relpath(new_libpath, dirname(path)))
    cmd = relink(old_libpath, origin_relpath)
    run(ur, cmd, logpath; verbose=verbose)

    return origin_relpath
end
