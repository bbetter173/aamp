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
 * @file AudioCMCDHeaders.h
 * @brief CMCD headers for audio segments (ot=a, i for init)
 */

#ifndef AudioCMCDHeaders_h
#define AudioCMCDHeaders_h

#include "CMCDHeaders.h"

/**
 * @class   AudioCMCDHeaders
 * @brief   AudioCMCDHeaders Context
 */
class AudioCMCDHeaders: public CMCDHeaders
{
public:
	AudioCMCDHeaders() : CMCDHeaders() {}

protected:
	std::string ObjectTypeToken() const override
	{
		if (mediaType == "INIT_AUDIO")
		{
			return "i";
		}
		return "a";
	}

	bool HasSegmentMetrics() const override { return true; }
};

#endif
