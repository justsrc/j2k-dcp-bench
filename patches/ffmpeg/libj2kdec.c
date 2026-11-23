/*
 * JPEG 2000 / HTJ2K decoding support via libj2k
 * Copyright (c) 2026 Justin Jacob
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * JPEG 2000 / HTJ2K decoder using libj2k (j2k-c C ABI).
 *
 * One codestream per packet: the packet is opened, decoded and closed on a
 * dedicated decoder instance. libj2k parallelizes a single decode internally
 * through its own shared thread pool, so no FFmpeg frame/slice threading is
 * wired up here.
 *
 * Current scope mirrors what the native jpeg2000 decoder handles for the
 * content this integration targets (DCI cinema codestreams, grayscale):
 * unsigned samples, 1 or 3 components, no chroma subsampling. Subsampled,
 * paletted, alpha, signed content and non-zero image origins are rejected for
 * now. Three-component images are emitted as xyz12le like the native decoder
 * does for DCI profiles; other 3-component colour spaces are not
 * distinguished yet.
 *
 * The decoder instance persists across packets: the first packet opens it,
 * later packets feed it (j2k_decoder_feed), which keeps libj2k's threads,
 * session and Metal state warm instead of re-creating them per frame. A
 * decoder poisoned by a panic or internal error is closed and reopened by
 * the next packet. Full-image full-resolution requests with one or three
 * unsigned components of equal precision take the native fast path
 * (j2k_decoder_output_info_native + j2k_decoder_decode_full_into), which
 * skips the batch engine's per-image planning; everything else keeps the
 * general j2k_decoder_output_info + j2k_decoder_decode_into route. The
 * "backend" option selects the decode backend: cpu, metal (strict: errors
 * when Metal is unavailable, and requires the full image at full
 * resolution), or auto (default: Metal for HTJ2K content, which the GPU
 * decodes faster, and CPU otherwise, since Metal is slower for classic
 * full-resolution content).
 */

#include "libavutil/common.h"
#include "libavutil/error.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "internal.h"
#include "thread.h"

#include <j2k.h>

enum {
    LIBJ2K_BACKEND_CPU = 0,
    LIBJ2K_BACKEND_METAL = 1,
    LIBJ2K_BACKEND_AUTO = 2,
};

typedef struct LibJ2KDecodeContext {
    /* Must be first: avcodec_open2 stores the codec's priv_class here and
     * libavutil's option machinery reads it from this offset. */
    AVClass *class;
    int reduction_factor;
    int backend;      /* LIBJ2K_BACKEND_*. */
    j2k_decoder *dec; /* Persistent decoder; NULL until the first packet. */
    int metal_ready;  /* j2k_decoder_metal_init has succeeded. */
} LibJ2KDecodeContext;

/* Close a decoder poisoned by a panic or internal error; the next packet
 * reopens a fresh instance. Closing a NULL handle is a no-op. */
static void libj2k_drop_decoder(LibJ2KDecodeContext *s)
{
    j2k_error err = { 0 };
    j2k_decoder_close(&s->dec, &err);
    s->dec = NULL;
}

/* libj2k delivers native-range samples (0..2^precision-1, right-aligned in the
 * sample word). FFmpeg's xyz12le packs 12-bit values into the upper bits of
 * each 16-bit word (descriptor shift 4), and 12-bit gray16 content is
 * likewise MSB-aligned; shifting in place reproduces the native decoder's
 * sample packing so both decoders produce identical bytes. Stride gaps are
 * respected, so padded linesizes stay untouched outside the written span. */
static void libj2k_shift_plane(uint8_t *base, ptrdiff_t linesize,
                               uint32_t height, size_t row_bytes,
                               unsigned shift)
{
    if (!shift)
        return;
    for (uint32_t y = 0; y < height; y++) {
        uint16_t *d = (uint16_t *)(base + (size_t)y * linesize);
        size_t n = row_bytes >> 1;
        for (size_t i = 0; i < n; i++)
            d[i] = (uint16_t)(d[i] << shift);
    }
}

static int libj2k_map_status(AVCodecContext *avctx, j2k_status st,
                             const j2k_error *err)
{
    if (err->message[0])
        av_log(avctx, AV_LOG_ERROR, "libj2k: %s\n", err->message);
    switch (st) {
    case J2K_INVALID_ARGUMENT:  return AVERROR(EINVAL);
    case J2K_INVALID_INPUT:
    case J2K_DECODE_FAILED:     return AVERROR_INVALIDDATA;
    case J2K_BUFFER_TOO_SMALL:
    case J2K_ALLOCATION_FAILED: return AVERROR(ENOMEM);
    case J2K_UNSUPPORTED:       return AVERROR_PATCHWELCOME;
    default:                    return AVERROR_EXTERNAL;
    }
}

static enum AVPixelFormat libj2k_select_pix_fmt(unsigned channels,
                                                unsigned precision,
                                                unsigned wide)
{
    if (channels == 3 && wide && precision >= 9 && precision <= 16)
        return AV_PIX_FMT_XYZ12LE;
    if (channels == 1) {
        if (!wide && precision <= 8)
            return AV_PIX_FMT_GRAY8;
        if (wide && precision >= 9 && precision <= 16)
            return AV_PIX_FMT_GRAY16LE;
    }
    return AV_PIX_FMT_NONE;
}

static av_cold int libj2k_init(AVCodecContext *avctx)
{
    LibJ2KDecodeContext *s = avctx->priv_data;

    if (avctx->lowres) {
        if (s->reduction_factor)
            return AVERROR(EINVAL);
        s->reduction_factor = avctx->lowres;
    }
    return 0;
}

static int libj2k_receive_frame(AVCodecContext *avctx, AVFrame *picture)
{
    LibJ2KDecodeContext *s = avctx->priv_data;
    AVPacket *const avpkt = avctx->internal->in_pkt;
    int ret;

    /* One codestream per packet, mirroring the native decoder. The decoder
     * instance persists across packets: the first packet opens it, later
     * packets feed it, which keeps libj2k's threads, session and Metal state
     * warm. A decoder poisoned by a panic or internal error is closed and
     * reopened by the next packet. */
    do {
        j2k_error err = { 0 };
        j2k_image_info ii = J2K_IMAGE_INFO_INIT;
        j2k_component_info ci = J2K_COMPONENT_INFO_INIT;
        j2k_output_info oi = J2K_OUTPUT_INFO_INIT;
        j2k_decode_options dopt = J2K_DECODE_OPTIONS_INIT;
        j2k_status st;
        enum AVPixelFormat pix_fmt;
        unsigned wide;
        int use_metal = 0, native_path = 0;

        ret = ff_decode_get_packet(avctx, avpkt);
        if (ret < 0)
            return ret;

        if (avctx->skip_frame >= AVDISCARD_ALL) {
            av_packet_unref(avpkt);
            continue;
        }

        if (!s->dec) {
            st = j2k_decoder_open(avpkt->data, avpkt->size, NULL, &s->dec, &err);
            if (st != J2K_OK) {
                s->dec = NULL;
                ret = libj2k_map_status(avctx, st, &err);
                goto fail;
            }
        } else {
            st = j2k_decoder_feed(s->dec, avpkt->data, avpkt->size, &err);
            if (st != J2K_OK) {
                ret = libj2k_map_status(avctx, st, &err);
                goto fail;
            }
        }

        st = j2k_decoder_info(s->dec, &ii, &err);
        if (st != J2K_OK) {
            ret = libj2k_map_status(avctx, st, &err);
            goto fail_dec;
        }
        if (ii.image_x0 || ii.image_y0) {
            av_log(avctx, AV_LOG_ERROR, "libj2k: non-zero image origin "
                   "(%u,%u) is not supported\n", ii.image_x0, ii.image_y0);
            ret = AVERROR_PATCHWELCOME;
            goto fail_dec;
        }
        if (ii.has_signed_components) {
            av_log(avctx, AV_LOG_ERROR, "libj2k: signed components are not "
                   "supported\n");
            ret = AVERROR_PATCHWELCOME;
            goto fail_dec;
        }

        st = j2k_decoder_component_info(s->dec, 0, &ci, &err);
        if (st != J2K_OK) {
            ret = libj2k_map_status(avctx, st, &err);
            goto fail_dec;
        }
        if (ci.is_signed || ci.sampling_x != 1 || ci.sampling_y != 1) {
            av_log(avctx, AV_LOG_ERROR, "libj2k: unsupported component "
                   "geometry (signed=%u, sampling %ux%u)\n",
                   ci.is_signed, ci.sampling_x, ci.sampling_y);
            ret = AVERROR_PATCHWELCOME;
            goto fail_dec;
        }

        dopt.reduction = s->reduction_factor;

        /* Backend selection. "metal" is strict: it errors when Metal is
         * unavailable. "auto" routes HTJ2K content to Metal (the GPU is
         * faster there and slower for classic full-resolution content) and
         * everything else to the CPU path. */
        if (s->backend != LIBJ2K_BACKEND_CPU) {
            uint32_t syntax = J2K_SYNTAX_OTHER;
            int ht;
            st = j2k_decoder_transfer_syntax(s->dec, &syntax, &err);
            if (st != J2K_OK) {
                ret = libj2k_map_status(avctx, st, &err);
                goto fail_dec;
            }
            ht = syntax == J2K_SYNTAX_HT_JPEG2000_LOSSLESS ||
                 syntax == J2K_SYNTAX_HT_JPEG2000_LOSSY;
            if (!s->metal_ready && (s->backend == LIBJ2K_BACKEND_METAL || ht)) {
                st = j2k_decoder_metal_init(s->dec, &err);
                if (st == J2K_OK) {
                    s->metal_ready = 1;
                } else if (s->backend == LIBJ2K_BACKEND_METAL) {
                    ret = libj2k_map_status(avctx, st, &err);
                    goto fail_dec;
                }
                /* auto: an unavailable Metal device keeps the CPU route. */
            }
            use_metal = s->metal_ready &&
                        (s->backend == LIBJ2K_BACKEND_METAL || ht);
        }

        /* Output layout: the native fast path covers full-image,
         * full-resolution, uniformly unsigned 1/3-component raw codestreams;
         * anything else keeps the batch-engine route. */
        if (dopt.reduction == 0) {
            st = j2k_decoder_output_info_native(s->dec, &dopt, &oi, &err);
            if (st == J2K_OK) {
                native_path = 1;
            } else if (st != J2K_UNSUPPORTED) {
                ret = libj2k_map_status(avctx, st, &err);
                goto fail_dec;
            }
        }
        if (!native_path) {
            if (use_metal) {
                av_log(avctx, AV_LOG_ERROR, "libj2k: the Metal backend "
                       "requires the full image at full resolution\n");
                ret = AVERROR_PATCHWELCOME;
                goto fail_dec;
            }
            st = j2k_decoder_output_info(s->dec, &dopt, &oi, &err);
            if (st != J2K_OK) {
                ret = libj2k_map_status(avctx, st, &err);
                goto fail_dec;
            }
        }

        wide = (oi.sample_type == J2K_U16_LE);
        pix_fmt = libj2k_select_pix_fmt(oi.channels, oi.precision, wide);
        if (pix_fmt == AV_PIX_FMT_NONE) {
            av_log(avctx, AV_LOG_ERROR, "libj2k: unsupported pixel layout: "
                   "channels=%u precision=%u sample_type=%u\n",
                   oi.channels, oi.precision, oi.sample_type);
            ret = AVERROR_PATCHWELCOME;
            goto fail_dec;
        }

        avctx->pix_fmt             = pix_fmt;
        avctx->bits_per_raw_sample = oi.precision;
        if ((ret = ff_set_dimensions(avctx, oi.width, oi.height)) < 0)
            goto fail_dec;

        /* get picture buffer */
        if ((ret = ff_thread_get_buffer(avctx, picture, 0)) < 0)
            goto fail_dec;

        /* Decode the whole interleaved image straight into the frame buffer.
         * The buffer's stride is the frame linesize; decode_into only writes
         * rows it needs (span), leaving any linesize padding untouched. */
        {
            size_t row_bytes = (size_t)oi.row_bytes;
            size_t span = (size_t)picture->linesize[0] * (oi.height - 1)
                          + row_bytes;

            if (span > (size_t)picture->buf[0]->size) {
                av_log(avctx, AV_LOG_ERROR, "libj2k: output span %zu exceeds "
                       "frame buffer %d\n", span, picture->buf[0]->size);
                ret = AVERROR_INVALIDDATA;
                goto fail_frame;
            }
            if (use_metal)
                st = j2k_decoder_metal_decode_into(s->dec, &dopt,
                                                   picture->data[0], span,
                                                   picture->linesize[0], &err);
            else if (native_path)
                st = j2k_decoder_decode_full_into(s->dec, &dopt,
                                                  picture->data[0], span,
                                                  picture->linesize[0], &err);
            else
                st = j2k_decoder_decode_into(s->dec, &dopt, picture->data[0],
                                             span, picture->linesize[0], &err);
            if (st != J2K_OK) {
                ret = libj2k_map_status(avctx, st, &err);
                goto fail_frame;
            }
            if (wide && oi.precision < 16)
                libj2k_shift_plane(picture->data[0], picture->linesize[0],
                                   oi.height, row_bytes, 16u - oi.precision);
        }

        picture->pkt_dts = avpkt->dts;
        av_packet_unref(avpkt);
        break;

fail_frame:
        av_frame_unref(picture);
        if (st == J2K_PANIC || st == J2K_INTERNAL_ERROR)
            libj2k_drop_decoder(s);
fail_dec:
        if (st == J2K_PANIC || st == J2K_INTERNAL_ERROR)
            libj2k_drop_decoder(s);
fail:
        picture->pkt_dts = avpkt->dts;
        av_packet_unref(avpkt);
        return ret;
    } while (1);

    return 0;
}

#define OFFSET(x) offsetof(LibJ2KDecodeContext, x)
#define VD AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_DECODING_PARAM

static const AVOption libj2k_options[] = {
    { "reduction_factor", "Lower the decoding resolution by a power of two",
      OFFSET(reduction_factor), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, 3, VD },
    { "backend", "Decode backend", OFFSET(backend), AV_OPT_TYPE_INT,
      { .i64 = LIBJ2K_BACKEND_AUTO }, 0, LIBJ2K_BACKEND_AUTO, VD, .unit = "backend" },
    { "cpu",   "libj2k CPU decode",              0, AV_OPT_TYPE_CONST, { .i64 = LIBJ2K_BACKEND_CPU },   0, 0, VD, .unit = "backend" },
    { "metal", "Metal GPU decode (strict)",      0, AV_OPT_TYPE_CONST, { .i64 = LIBJ2K_BACKEND_METAL }, 0, 0, VD, .unit = "backend" },
    { "auto",  "Metal for HTJ2K, CPU otherwise", 0, AV_OPT_TYPE_CONST, { .i64 = LIBJ2K_BACKEND_AUTO },  0, 0, VD, .unit = "backend" },
    { NULL },
};

static const AVClass libj2k_class = {
    .class_name = "libj2k",
    .item_name  = av_default_item_name,
    .option     = libj2k_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static av_cold int libj2k_close(AVCodecContext *avctx)
{
    LibJ2KDecodeContext *s = avctx->priv_data;

    /* Closing a NULL handle is a no-op. */
    libj2k_drop_decoder(s);
    return 0;
}

const FFCodec ff_libj2k_decoder = {
    .p.name           = "libj2k",
    CODEC_LONG_NAME("JPEG 2000 / HTJ2K (libj2k)"),
    .p.type           = AVMEDIA_TYPE_VIDEO,
    .p.id             = AV_CODEC_ID_JPEG2000,
    .p.capabilities   = AV_CODEC_CAP_DR1,
    .priv_data_size   = sizeof(LibJ2KDecodeContext),
    .init             = libj2k_init,
    .close            = libj2k_close,
    FF_CODEC_RECEIVE_FRAME_CB(libj2k_receive_frame),
    .p.priv_class     = &libj2k_class,
    .p.max_lowres     = 3,
};
