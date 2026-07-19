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
 * @file CMCDSerializer.cpp
 * @brief Implementation of CTA-5004 §3 CMCD serialization primitives.
 *
 * Provides pure, dependency-free implementations of RoundToNearest100,
 * QuoteString, CMCDGroupToHeaderKey, and SerializeToCMCDMap. These functions
 * are the single point of truth for CMCD key encoding, rounding, quoting,
 * and alphabetical ordering within each header group.
 */

#include "CMCDSerializer.h"

#include <algorithm>
#include <map>
#include <string>

int RoundToNearest100(int value)
{
    if (value <= 0)
    {
        return 0; // negative/zero treated as "unavailable" — prevents INT_MIN+50 overflow
    }
    return ((value + 50) / 100) * 100;
}

std::string QuoteString(std::string_view value)
{
    std::string result;
    result.reserve(value.size() + 2);
    result += '"';
    for (char c : value)
    {
        if (c == '"' || c == '\\')
        {
            result += '\\';
        }
        result += c;
    }
    result += '"';
    return result;
}

std::string CMCDGroupToHeaderKey(CMCDGroup group)
{
    switch (group)
    {
        case CMCDGroup::Object:
            return "CMCD-Object:";
        case CMCDGroup::Request:
            return "CMCD-Request:";
        case CMCDGroup::Session:
            return "CMCD-Session:";
        case CMCDGroup::Status:
            return "CMCD-Status:";
    }
    return "CMCD-Object:";
}

/**
 * @brief Split a comma-delimited CMCD group value into tokens, ignoring commas
 *        inside quoted strings.
 *
 * Quoted-string values (sid/cid/nor/nrr) may legally contain commas, so a naive
 * find(',') split would cut a token in half. Tracks double-quote state and skips
 * the character after a backslash (QuoteString escapes '"' and '\\' with '\\').
 * Appends the resulting tokens to tokens.
 */
static void SplitTokensQuoteAware(const std::string& value, std::vector<std::string>& tokens)
{
    std::string current;
    bool inQuotes = false;
    bool escaped = false;
    for (char c : value)
    {
        if (escaped)
        {
            current += c;
            escaped = false;
        }
        else if (inQuotes && c == '\\')
        {
            current += c;
            escaped = true;
        }
        else if (c == '"')
        {
            current += c;
            inQuotes = !inQuotes;
        }
        else if (c == ',' && !inQuotes)
        {
            tokens.push_back(current);
            current.clear();
        }
        else
        {
            current += c;
        }
    }
    if (!current.empty())
    {
        tokens.push_back(current);
    }
}

void SerializeToCMCDMap(const std::vector<CMCDEntry>& entries,
                        std::unordered_map<std::string, std::vector<std::string>>& out)
{
    // Sort a local copy alphabetically by key (CTA-5004 §3 alphabetical ordering).
    std::vector<CMCDEntry> sorted = entries;
    std::sort(sorted.begin(), sorted.end(),
              [](const CMCDEntry& a, const CMCDEntry& b) { return a.key < b.key; });

    // Use std::map to accumulate comma-joined value per group (deterministic key order).
    std::map<std::string, std::string> groups;

    for (const auto& e : sorted)
    {
        std::string headerKey = CMCDGroupToHeaderKey(e.group);
        std::string token;

        if (e.isBoolToken)
        {
            if (e.value == "1")
            {
                token = e.key; // bare key only
            }
            else
            {
                continue; // omit when false
            }
        }
        else if (e.isInteger)
        {
            if (e.value.empty())
            {
                continue; // treat missing integer as "unavailable" — omit entry
            }
            int parsed = 0;
            try
            {
                parsed = std::stoi(e.value);
            }
            catch (const std::exception&)
            {
                continue; // malformed value — omit rather than crash
            }
            int r = RoundToNearest100(parsed);
            if (r == 0)
            {
                continue; // omit zero per CTA-5004 optional-key rule
            }
            token = e.key + "=" + std::to_string(r);
        }
        else if (e.isQuotedString)
        {
            token = e.key + "=" + QuoteString(e.value);
        }
        else
        {
            token = e.key + "=" + e.value; // bare token value (e.g. ot=v)
        }

        if (!groups[headerKey].empty())
        {
            groups[headerKey] += ",";
        }
        groups[headerKey] += token;
    }

    // Merge each group's joined value into the output map.
    // If a group key already exists in out, split the pre-existing comma-delimited
    // tokens, combine with the new tokens, re-sort all tokens alphabetically by
    // their key (the substring before '=', or the whole token for bare booleans),
    // and rejoin.  This ensures that two sequential SerializeToCMCDMap calls
    // targeting the same group produce a single correctly-sorted value rather
    // than silently discarding the first call.
    for (const auto& kv : groups)
    {
        auto it = out.find(kv.first);
        if (it == out.end() || it->second.empty() || it->second.at(0).empty())
        {
            // No pre-existing entry — write directly.
            out[kv.first] = {kv.second};
        }
        else
        {
            // Pre-existing entry present — merge tokens and re-sort by key.
            std::vector<std::string> tokens;
            SplitTokensQuoteAware(it->second.at(0), tokens);
            SplitTokensQuoteAware(kv.second, tokens);

            // Sort all tokens alphabetically by their CMCD key name.
            // For a token like "br=3800" the key is "br"; for bare "bs" the key is "bs".
            std::sort(tokens.begin(), tokens.end(),
                [](const std::string& a, const std::string& b)
                {
                    const std::string keyA = a.substr(0, a.find('='));
                    const std::string keyB = b.substr(0, b.find('='));
                    return keyA < keyB;
                });

            // Rejoin into a single comma-delimited string.
            std::string merged;
            for (const auto& tok : tokens)
            {
                if (!merged.empty())
                {
                    merged += ',';
                }
                merged += tok;
            }
            it->second = {merged};
        }
    }
}
