// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef TEXTURE_GL_H_
#define TEXTURE_GL_H_

#include <flutter_linux/flutter_linux.h>

#include "video_output.h"

#define TEXTURE_GL_TYPE (texture_gl_get_type())

G_DECLARE_FINAL_TYPE(TextureGL, texture_gl, TEXTURE_GL, TEXTURE_GL, FlTextureGL)

#define TEXTURE_GL(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), texture_gl_get_type(), TextureGL))

TextureGL* texture_gl_new(VideoOutput* video_output);

/**
 * @brief Waits for a populate in progress, frees what the texture made in
 * mpv's isolated EGL context and detaches it from its |VideoOutput|. Every
 * later populate draws the last frame without touching the |VideoOutput|,
 * mpv or the isolated context: Flutter looks a texture up without taking a
 * reference, so a populate can still start shortly after the texture is
 * unregistered. Called before mpv's render context is freed.
 */
void texture_gl_release(TextureGL* self);

/**
 * @brief Populates texture with video frame.
 */
gboolean texture_gl_populate_texture(FlTextureGL* texture,
                                     guint32* target,
                                     guint32* name,
                                     guint32* width,
                                     guint32* height,
                                     GError** error);

#endif  // TEXTURE_GL_H_
