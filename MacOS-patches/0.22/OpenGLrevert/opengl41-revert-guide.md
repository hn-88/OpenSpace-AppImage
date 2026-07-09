# Ghoul OpenGL 4.1 patch — updated for current master

This replaces the earlier guide. It's based on an actual diff between
`332c397635d96ee9296564f1bfd8e17eac5318ef` (pre-4.6) and current master
(`bd7bd9dac969c15cfe5dfe51c7efd6ee1fe5c0f4`), not just the original 4.6 commit.

## What changed since my first answer

That range spans **190 changed files** — CMake bumps, submodule URL fixes,
socket/logging/lua refactors, test changes, and so on — almost none of it
related to OpenGL. Trying to "revert" all of that would throw away a lot of
unrelated fixes you want to keep. So instead of reverting history, the patch
below **modifies current master directly**, converting only the OpenGL
4.5/4.6-only (DSA) and 4.3-only (`glObjectLabel`/`glPushDebugGroup`) calls
back to OpenGL 4.1-compatible equivalents, leaving everything else — all the
naming, refactors, and new features from the last ~year+ of development —
untouched.

Also worth knowing: **`VertexBufferObject` and `texture.inl` no longer exist**
in current master — they were deleted at some point in that range.
`fontrenderer.cpp` and `modelmesh.cpp` now manage their own VAOs/VBOs
directly, which is what's patched below.

## Files patched (9 total)

| File | What changed for 4.1 |
|---|---|
| `include/ghoul/opengl/ghoul_gl.h` | `gl46core` → `gl41core`; guard `glPushDebugGroup`/`glPopDebugGroup` |
| `include/ghoul/opengl/texture.h` | Added public `bind()` (needed since DSA calls that didn't require a bind are gone) |
| `src/opengl/texture.cpp` | All `glCreateTextures`/`glTexture*`/`glGetTextureImage` DSA calls → classic bind + `glTex*`/`glGetTexImage`; guarded `glObjectLabel` |
| `include/ghoul/opengl/textureunit.h` | `bind(GLuint)` → `bind(const Texture&)` so the classic path knows the texture's target enum |
| `src/opengl/textureunit.cpp` | `glBindTextureUnit` (GL 4.5) → classic `glActiveTexture` + `Texture::bind()` |
| `src/font/fontrenderer.cpp` | VAO/VBO setup and `glNamedBufferData` → classic `glGen*`/`glBindBuffer`/`glBufferData`/`glVertexAttribPointer` |
| `src/io/model/modelmesh.cpp` | Same conversion as fontrenderer, plus `glNamedBufferStorage` (immutable, GL 4.4) → mutable `glBufferData` |
| `src/opengl/framebufferobject.cpp` | `glCreateFramebuffers`/`glNamedFramebufferTexture(Layer)` → classic `glGenFramebuffers` + bind + `glFramebufferTexture`/`glFramebufferTextureLayer` (both core since GL 3.2) |
| `src/opengl/programobject.cpp`, `src/opengl/shaderobject.cpp` | Guarded `glObjectLabel` calls |

Calls left untouched because they're already GL 4.1-safe: `glProgramUniform*`
(`ARB_separate_shader_objects`, core in 4.1), `glValidateProgram`,
`glCreateProgram`/`glCreateShader` (these are original core GL 2.0 functions,
not part of the DSA family despite the name).

## How to apply

From the root of your Ghoul checkout:

```sh
git apply --check ghoul-opengl41-macos.patch   # dry run, should print nothing
git apply ghoul-opengl41-macos.patch
```

If your checked-out commit has drifted slightly from
`bd7bd9dac969c15cfe5dfe51c7efd6ee1fe5c0f4`, `git apply` may complain about
context mismatches. In that case try:

```sh
git apply --3way ghoul-opengl41-macos.patch
```

which will merge what it can and leave conflict markers for the rest.

## After applying

- Double check `glTexStorage1D/2D/3D` (in `texture.cpp`) actually resolves on
  your Mac's context — it's `ARB_texture_storage`, core since GL 4.2, not 4.1,
  but macOS has historically exposed it as an extension on 4.1 contexts. If it
  doesn't resolve for you, that function needs falling back to
  `glTexImage1D/2D/3D` + separate mipmap level allocation, which is a slightly
  bigger change I didn't include here since it's likely fine on Mac in practice.
- Grep your own OpenSpace/rendering code (outside Ghoul) for the same
  patterns (`glCreate*`, `glNamed*`, `glVertexArrayAttrib*`,
  `glBindTextureUnit`) in case renderables elsewhere picked up DSA calls too.
