# Libraries behind the Discord features

The Discord features (Settings > Discord features, the Social tab) use these libraries, built for iOS by `tools/build_dave.sh` from the sources named here and linked
into the app. Porthole changes none of them. Their licence texts are in "Discord-libraries-licences". Porthole is not made by Discord and is not an official Discord client.

| Library | What it does here | Licence | Source (exact version) |
|---|---|---|---|
| **libdave** (Discord) | DAVE, Discord's end-to-end encryption of calls | MIT | https://github.com/discord/libdave, commit 6396c90aedbb9a6ee117ea9ce1ce9832af6a3375 |
| **mlspp** (Cisco) | Messaging Layer Security, used by libdave | BSD-2-Clause | https://github.com/cisco/mlspp, commit 1cc50a124a3bc4e143a787ec934280dc70c1034d |
| **OpenSSL 3.0.18** | cryptography for libdave and the voice connection | Apache-2.0 | https://github.com/openssl/openssl/releases/tag/openssl-3.0.18 |
| **nlohmann/json 3.11.3** | JSON in libdave | MIT | https://github.com/nlohmann/json, tag v3.11.3 |
| **libdatachannel** (Paul-Louis Ageneau) | the WebRTC connection (watching streams) | **MPL-2.0** | https://github.com/paullouisageneau/libdatachannel, commit 6b1e2e620f1e37f0eafeee702eaea0043cb305fd |
| **libjuice** (Paul-Louis Ageneau) | ICE (finding a route) inside libdatachannel | **MPL-2.0** | https://github.com/paullouisageneau/libjuice, commit b89c792e3612faf2f12cf35bcc56857313a06be3 |
| **libsrtp** (Cisco) | encrypted audio and video packets | BSD-3-Clause | https://github.com/cisco/libsrtp, commit 24b3bf8f19b6f5ab4cd2bcceb4f4064efca86fd5 |
| **usrsctp** (Randall Stewart, Michael Tüxen) | data channel transport | BSD-3-Clause | https://github.com/paullouisageneau/usrsctp, commit fec583d54493f879d2ae44a743423bf8a04371ab |
| **plog** (Sergey Podobry) | logging inside libdatachannel | MIT | https://github.com/SergiusTheBest/plog, commit 94899e0b926ac1b0f4750bfbd495167b4a6ae9ef |
| **Opus 1.5.2** (Xiph.Org and others) | the voice codec | BSD-3-Clause | https://github.com/xiph/opus, tag v1.5.2 |

**The Mozilla Public License parts.** libdatachannel and libjuice are under the MPL 2.0. Their source code is public at the addresses above, and anyone may get it from there.
Their files stay under the MPL; Porthole's own files are not part of them.

**Not affiliated.** Discord, Cisco, OpenSSL and the other names belong to their owners. Using Discord through a program that is not Discord's own is against Discord's terms; read the warning in Settings first.
