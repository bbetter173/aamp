/*
 * If not stated otherwise in this file or this component's license file the
 * following copyright and licenses apply:
 *
 *   Copyright 2022 RDK Management
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */

/**
 * @file CMCDHeaders.cpp
 * @brief CMCD key state and header assembly
 */
#include "CMCDHeaders.h"
#include "CMCDSerializer.h"
#include <algorithm>
#include <cstdio>
#include <cmath>
using namespace std;

/**
 * @brief Format a playback rate as a plain decimal string with no trailing zeros.
 *
 * Uses snprintf with the %g format specifier to strip unnecessary trailing zeros:
 * 2.0f -> "2", 1.5f -> "1.5", 0.5f -> "0.5". Avoids std::to_string which
 * produces "2.000000" for floating-point values.
 *
 * @param rate Playback rate value to format.
 * @return Formatted decimal string suitable for CMCD pr token emission.
 */
static std::string FormatPlaybackRate(float rate)
{
	char buf[32];
	std::snprintf(buf, sizeof(buf), "%g", static_cast<double>(rate));
	return std::string(buf);
}

/**
 * @brief   SetNetworkMetrics
 * @param   startTransferTime time to first byte
 * @param   totalTime time to last byte
 * @param   dnsLookUpTime dns look up time
 */
void CMCDHeaders::SetNetworkMetrics(const int &startTransferTime,const int &totalTime,const int &dnsLookUpTime)
{
	firstByte = startTransferTime;
	lastByte = totalTime;
	dnsLookUptime = dnsLookUpTime;

}

/**
 * @brief   GetNetworkMetrics
 * @param   startTransferTime time to first byte
 * @param   totalTime time to last byte
 * @param   dnsLookUpTime dns look up time
 */
void CMCDHeaders::GetNetworkMetrics(int &startTransferTime, int &totalTime, int &dnsLookUpTime)
{
	startTransferTime = firstByte;
	totalTime = lastByte;
	dnsLookUpTime = dnsLookUptime;
}

/**
 * @brief   SetSessionId
 * @param   sid session id to be set
 */
void  CMCDHeaders::SetSessionId(const std::string &sid)
{
	sessionId = sid;
}

/**
 * @brief   GetSessionId
 * @param   sid session id
 */
std::string  CMCDHeaders::GetSessionId()
{
	return sessionId;
}

/**
 * @brief   SetMediaType
 * @param   mediaTypeName type of media
 */
void  CMCDHeaders::SetMediaType(const std::string &mediaTypeName )
{
	mediaType = mediaTypeName;
}

/**
 * @brief   SetNextUrl
 * @param   url
 */
void  CMCDHeaders::SetNextUrl(const std::string &url)
{
	nextUrl = url;
}

/**
 * @brief   SetBitrate
 * @param   Bandwidth
 */
void  CMCDHeaders::SetBitrate(const int &Bandwidth)
{
	bitrate = Bandwidth;
}

/**
 * @brief   SetTopBitrate
 * @param   Bandwidth
 */
void  CMCDHeaders::SetTopBitrate(const int &Bandwidth)
{
	topBitrate = Bandwidth;
}

/**
 * @brief   SetBufferLength
 * @param   bufferlength
 */
void  CMCDHeaders::SetBufferLength(const int &bufferlength)
{
	bufferLength = bufferlength;
}

/**
 * @brief   SetBufferStarvation
 * @param   bufferStarvation true latches a starvation (rebuffer/underrun) for the next request
 *
 * Latched, not level-triggered: a true value is sticky and is cleared only once it has been
 * reported as the CMCD bs token (see AppendSegmentEntries). A false value is ignored, so a
 * starvation seen between two requests is still reported on the resumption request —
 * CTA-5004 §3: bs marks the buffer being starved at some point since the prior request.
 */
void  CMCDHeaders::SetBufferStarvation(const bool &bufferStarvation)
{
	if (bufferStarvation)
	{
		this->bufferStarvation = true;
	}
}

/**
 * @brief   GetMediaType
 */
std::string  CMCDHeaders::GetMediaType()
{
	return mediaType;
}

/**
 * @brief   SetNextRange -> SegmentBase MPD
 * @param   nextrange the next byte range to be requested
 */
void  CMCDHeaders::SetNextRange(const std::string &nextrange)
{
	mNextRange = nextrange;
}

/**
 * @brief   BuildCMCDCustomHeaders
 * @param   map which collects formatted CMCD headers
 *
 * Template method shared by all media types. Builds the Session group entries,
 * the subclass object type token, and (for media segment types) the segment
 * metric entries, then serializes everything in one pass — the serializer
 * encodes each entry, sorts keys alphabetically within each group, and joins
 * them into one comma-delimited value per CMCD header.
 */
void CMCDHeaders::BuildCMCDCustomHeaders(std::unordered_map<std::string, std::vector<std::string>> &mCMCDCustomHeaders)
{
	mCMCDCustomHeaders.clear();
	std::vector<CMCDEntry> entries;

	// --- CMCD-Session group ---

	// sid — quoted-string token, always present
	entries.push_back(CMCDEntry{"sid", sessionId, CMCDGroup::Session, false, true, false});

	// v=1 — constant bare token, always present
	entries.push_back(CMCDEntry{"v", "1", CMCDGroup::Session, false, false, false});

	// sf — bare token; omit when streaming format is not yet determined
	if (!mStreamingFormat.empty())
	{
		entries.push_back(CMCDEntry{"sf", mStreamingFormat, CMCDGroup::Session, false, false, false});
	}

	// st — bare token; omit before first manifest parse (mStreamType empty)
	if (!mStreamType.empty())
	{
		entries.push_back(CMCDEntry{"st", mStreamType, CMCDGroup::Session, false, false, false});
	}

	// pr — bare decimal token. Per CTA-5004 pr is the actual playback rate (1 = real-time,
	// 2 = double speed, 0 = not playing) and SHOULD be sent whenever it is not 1. So 0 is a
	// valid value that MUST be emitted (it signals "not playing"); only 1x is omitted.
	// Use epsilon comparison rather than exact float equality: 1.0f has an exact
	// IEEE-754 representation and AAMP_NORMAL_PLAY_RATE is integer 1 (promoted to
	// 1.0f), so equality holds in practice — but a future double-to-float conversion
	// could produce a value indistinguishable from 1 that fails the strict check.
	static constexpr float kNormalPlayRate = 1.0f;
	static constexpr float kPlayRateEps    = 1e-4f;
	if (std::fabs(mPlaybackRate - kNormalPlayRate) > kPlayRateEps)
	{
		entries.push_back(CMCDEntry{"pr", FormatPlaybackRate(mPlaybackRate), CMCDGroup::Session, false, false, false});
	}

	// cid — quoted-string token; omit when no content id is available
	if (!mContentId.empty())
	{
		entries.push_back(CMCDEntry{"cid", mContentId, CMCDGroup::Session, false, true, false});
	}

	// --- CMCD-Object: ot token (subclass-specific) ---
	const std::string ot = ObjectTypeToken();
	if (!ot.empty())
	{
		entries.push_back(CMCDEntry{"ot", ot, CMCDGroup::Object});
	}

	// --- Segment metrics (media segment types only) ---
	if (HasSegmentMetrics())
	{
		AppendSegmentEntries(entries);
	}

	SerializeToCMCDMap(entries, mCMCDCustomHeaders);
}

/**
 * @brief Append the segment-metric entries shared by all media segment types
 *        (br/tb/bl/d/dl/mtp/su/bs/rtp, nor/nrr, and custom keys).
 */
void CMCDHeaders::AppendSegmentEntries(std::vector<CMCDEntry> &entries)
{
	// br and tb: kbps integers — serializer applies RoundToNearest100 and omits zeros.
	entries.push_back(CMCDEntry{"br", std::to_string(bitrate), CMCDGroup::Object, true});
	entries.push_back(CMCDEntry{"tb", std::to_string(topBitrate), CMCDGroup::Object, true});

	// bl: buffer length in ms — serializer rounds and omits zero.
	entries.push_back(CMCDEntry{"bl", std::to_string(bufferLength), CMCDGroup::Request, true});

	// d: object duration in ms — NOT rounded (all CMCDEntry flags false = default bare token).
	// Plain integer ms per CTA-5004 §3.
	if (mFragmentDuration > 0)
	{
		entries.push_back(CMCDEntry{"d", std::to_string(mFragmentDuration), CMCDGroup::Object});
	}

	// dl: deadline in ms = buffered duration / playback rate — isInteger rounds to 100 ms.
	// kMinRate floor prevents division blow-up at pause/near-zero rate.
	if (bufferLength > 0)
	{
		static constexpr float kMinRate = 0.5f;
		float safeRate = std::max(std::fabs(mPlaybackRate), kMinRate);
		int dlMs = static_cast<int>(static_cast<float>(bufferLength) / safeRate);
		entries.push_back(CMCDEntry{"dl", std::to_string(dlMs), CMCDGroup::Request, true});
	}

	// mtp: measured throughput in kbps — isInteger rounds to 100 kbps.
	if (mMeasuredThroughput > 0)
	{
		entries.push_back(CMCDEntry{"mtp", std::to_string(mMeasuredThroughput), CMCDGroup::Request, true});
	}

	// su: startup-urgent bare token — isBoolToken, identical pattern to bs.
	if (mStartupUrgent)
	{
		entries.push_back(CMCDEntry{"su", "1", CMCDGroup::Request, false, false, true});
	}

	// bs: boolean bare token — emitted when a starvation has been latched since the last
	// request, then cleared so it reports once on resumption (CTA-5004 §3 interval semantics).
	if (bufferStarvation)
	{
		entries.push_back(CMCDEntry{"bs", "1", CMCDGroup::Status, false, false, true});
		bufferStarvation = false;
	}

	// rtp: requested max throughput = bitrate * 2, rounded to 100 kbps via isInteger.
	// Factor of 2 per CTA-5004 client-discretion clause; matches ExoPlayer community default.
	if (bitrate > 0)
	{
		static constexpr float kRtpFactor = 2.0f;
		int rtpKbps = static_cast<int>(bitrate * kRtpFactor);
		entries.push_back(CMCDEntry{"rtp", std::to_string(rtpKbps), CMCDGroup::Status, true});
	}

	// nor / nrr / custom keys: nor and nrr are wrapped in double-quotes
	// (isQuotedString=true). AAMP segment paths are already URL-safe ASCII, so
	// quoting without percent-encoding is sufficient. Custom keys are bare
	// integers (NOT isInteger) to preserve raw unrounded values — they are
	// outside the kbps/ms rounding scope.
	if (dnsLookUptime > 0)
	{
		// Only emit nor if the next URL is known — CTA-5004 optional-key rule.
		if (!nextUrl.empty())
		{
			entries.push_back(CMCDEntry{"nor", nextUrl, CMCDGroup::Request, false, true});
		}
		entries.push_back(CMCDEntry{"com.comcast-dns", std::to_string(dnsLookUptime), CMCDGroup::Request});
		entries.push_back(CMCDEntry{"com.comcast-fb", std::to_string(firstByte), CMCDGroup::Request});
		entries.push_back(CMCDEntry{"com.comcast-lb", std::to_string(lastByte), CMCDGroup::Request});
	}
	else if (!mNextRange.empty())
	{
		entries.push_back(CMCDEntry{"nrr", mNextRange, CMCDGroup::Request, false, true});
		entries.push_back(CMCDEntry{"com.comcast-fb", std::to_string(firstByte), CMCDGroup::Request});
		entries.push_back(CMCDEntry{"com.comcast-lb", std::to_string(lastByte), CMCDGroup::Request});
	}
	else if (!nextUrl.empty())
	{
		entries.push_back(CMCDEntry{"nor", nextUrl, CMCDGroup::Request, false, true});
		entries.push_back(CMCDEntry{"com.comcast-fb", std::to_string(firstByte), CMCDGroup::Request});
		entries.push_back(CMCDEntry{"com.comcast-lb", std::to_string(lastByte), CMCDGroup::Request});
	}
}
