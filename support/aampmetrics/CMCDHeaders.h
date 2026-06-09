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
 * @file CMCDHeaders.h
 * @brief Per-media-type CMCD (CTA-5004) state and header assembly.
 *
 * CMCDHeaders holds the CMCD key state for one media type and assembles the
 * four CMCD request headers via BuildCMCDCustomHeaders (a template method).
 * Subclasses customise only the object type token (ot) and whether segment
 * metrics (br/tb/bl/d/dl/mtp/su/bs/rtp/nor/nrr) are reported.
 */

#ifndef CMCDHeaders_h
#define CMCDHeaders_h

#include <string>
#include <unordered_map>
#include <vector>

struct CMCDEntry;

const std::string CMCDSession = "sid=";

/**
 * @class   CMCDHeaders
 * @brief   CMCD key state and header assembly for one media type
 */
class CMCDHeaders
{
protected:
	std::string sessionId;
	std::string mediaType;
	int firstByte;
	int lastByte;
	int dnsLookUptime;
	int bitrate;
	int topBitrate;
	int bufferLength;
	bool bufferStarvation; ///< CMCD bs: latched on starvation, sticky until reported, then cleared
	std::string nextUrl;
	std::string mNextRange;
	std::string mStreamingFormat; ///< CMCD sf token: "d" (DASH), "h" (HLS), "s" (Smooth); empty = omit
	std::string mStreamType;      ///< CMCD st token: "v" (VOD) or "l" (live); empty = omit until known
	std::string mContentId;       ///< CMCD cid value (quoted-string); empty = omit
	float mPlaybackRate;          ///< CMCD pr value; 1.0f = normal play (pr omitted)
	int mFragmentDuration;        ///< CMCD d value: object duration in ms; 0 = omit
	int mMeasuredThroughput;      ///< CMCD mtp value: measured throughput in kbps; 0 = omit
	bool mStartupUrgent;          ///< CMCD su flag: true when request is startup/seek/rebuffer urgent

	/**
	 * @brief CMCD object type token (ot) for this media type.
	 * @return "v"/"a"/"i"/"av"/"m"/"s" per subclass; empty string omits the ot key.
	 */
	virtual std::string ObjectTypeToken() const { return std::string(); }

	/**
	 * @brief Whether this media type reports segment metrics
	 *        (br/tb/bl/d/dl/mtp/su/bs/rtp/nor/nrr and custom keys).
	 *        True for media segment types (video/audio); false for manifests/subtitles.
	 */
	virtual bool HasSegmentMetrics() const { return false; }

private:
	/**
	 * @brief Append the segment-metric entries shared by all media segment types.
	 *        Consumes the bs latch (reported once, then cleared).
	 */
	void AppendSegmentEntries(std::vector<CMCDEntry> &entries);

public:
	CMCDHeaders() : sessionId(""), mediaType(""), firstByte(0), lastByte(0), dnsLookUptime(0), bitrate(0), topBitrate(0), bufferLength(0), bufferStarvation(false), nextUrl(""), mNextRange(""), mStreamingFormat(""), mStreamType(""), mContentId(""), mPlaybackRate(1.0f), mFragmentDuration(0), mMeasuredThroughput(0), mStartupUrgent(false) {}
	virtual void SetNetworkMetrics(const int &startTransferTime,const int &totalTime,const int &dnsLookUpTime);
	virtual void GetNetworkMetrics(int &startTransferTime, int &totalTime, int &dnsLookUpTime);
	virtual void SetSessionId(const std::string &sid);
	virtual std::string GetSessionId();
	virtual void SetMediaType(const std::string &mediaTypeName);
	virtual void SetBitrate(const int &Bandwidth);
	virtual void SetTopBitrate(const int &Bandwidth);
	virtual void SetBufferLength(const int &bufferlength);
	virtual void SetBufferStarvation(const bool &bufferstarvation);
	virtual std::string GetMediaType();
	virtual void SetNextUrl(const std::string &url);
	virtual void SetNextRange(const std::string &nextrange);

	/**
	 * @brief Assemble the CMCD request headers from the current key state.
	 *
	 * Template method: emits the Session group (sid, v, sf, st, pr, cid), the
	 * subclass ObjectTypeToken() as ot, and — when HasSegmentMetrics() — the
	 * segment metric keys, all encoded and sorted by the CTA-5004 serializer.
	 *
	 * @param mCMCDCustomHeaders output map keyed by header name (e.g. "CMCD-Object:")
	 *        with the joined value string at element [0]
	 */
	virtual void BuildCMCDCustomHeaders(std::unordered_map<std::string, std::vector<std::string>> &mCMCDCustomHeaders);

	/** @brief Set the CMCD streaming format token (sf). Call with "d", "h", or "s". */
	void SetStreamingFormat(const std::string &sf) { mStreamingFormat = sf; }

	/** @brief Set the CMCD stream type token (st). Call with "v" (VOD) or "l" (live). */
	void SetStreamType(const std::string &st) { mStreamType = st; }

	/** @brief Set the CMCD content identifier (cid). Quoted-string; empty string omits the key. */
	void SetContentId(const std::string &cid) { mContentId = cid; }

	/** @brief Set the CMCD playback rate (pr). Emitted only when rate != 1.0f. */
	void SetPlaybackRate(float rate) { mPlaybackRate = rate; }

	/** @brief Set the CMCD object duration (d) in milliseconds. 0 omits the key. */
	void SetFragmentDuration(int durationMs) { mFragmentDuration = durationMs; }

	/** @brief Set the CMCD measured throughput (mtp) in kbps. 0 omits the key. */
	void SetMeasuredThroughput(int kbps) { mMeasuredThroughput = kbps; }

	/** @brief Set the CMCD startup-urgent flag (su). Emits the bare su token when true. */
	void SetStartupUrgent(bool startupUrgent) { mStartupUrgent = startupUrgent; }

	virtual ~CMCDHeaders() {};
};

#endif
