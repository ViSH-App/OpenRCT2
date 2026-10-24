/*****************************************************************************
 * Copyright (c) 2014-2026 OpenRCT2 developers
 *
 * For a complete list of all authors, please refer to contributors.md
 * Interested in contributing? Visit https://github.com/OpenRCT2/OpenRCT2
 *
 * OpenRCT2 is licensed under the GNU General Public License version 3.
 *****************************************************************************/

#if !defined(DISABLE_NETWORK) && defined(OPENRCT2_IOS)

    #pragma GCC diagnostic push
    #pragma GCC diagnostic ignored "-Wdeprecated-declarations"

    #include "Crypt.h"

    #include <CommonCrypto/CommonDigest.h>
    #include <Security/Security.h>
    #include <algorithm>
    #include <stdexcept>
    #include <string>
    #include <vector>

using namespace OpenRCT2::Crypt;

// Owns a Core Foundation reference and releases it when it goes out of scope.
template<typename T>
class CFRef
{
private:
    T _ref{};

public:
    CFRef() = default;
    explicit CFRef(T ref)
        : _ref(ref)
    {
    }
    CFRef(const CFRef&) = delete;
    CFRef& operator=(const CFRef&) = delete;
    ~CFRef()
    {
        Reset();
    }

    T Get() const
    {
        return _ref;
    }

    void Reset(T ref = nullptr)
    {
        if (_ref != nullptr)
        {
            CFRelease(_ref);
        }
        _ref = ref;
    }
};

static std::string DescribeError(CFErrorRef error)
{
    if (error == nullptr)
    {
        return "unknown error";
    }
    CFRef<CFStringRef> description(CFErrorCopyDescription(error));
    CFRelease(error);
    char buffer[256]{};
    if (description.Get() == nullptr
        || !CFStringGetCString(description.Get(), buffer, sizeof(buffer), kCFStringEncodingUTF8))
    {
        return "unknown error";
    }
    return buffer;
}

static std::vector<uint8_t> ToVector(CFDataRef data)
{
    auto bytes = CFDataGetBytePtr(data);
    return std::vector<uint8_t>(bytes, bytes + CFDataGetLength(data));
}

template<typename TBase, typename TContext, int (*TInit)(TContext*), int (*TUpdate)(TContext*, const void*, CC_LONG),
         int (*TFinal)(unsigned char*, TContext*)>
class AppleHashAlgorithm final : public TBase
{
private:
    TContext _ctx{};
    bool _initialised{};

public:
    TBase* Clear() override
    {
        TInit(&_ctx);
        _initialised = true;
        return this;
    }

    TBase* Update(const void* data, size_t dataLen) override
    {
        // Auto initialise
        if (!_initialised)
        {
            Clear();
        }

        auto bytes = static_cast<const uint8_t*>(data);
        while (dataLen > 0)
        {
            auto chunk = static_cast<CC_LONG>(std::min<size_t>(dataLen, UINT32_MAX));
            TUpdate(&_ctx, bytes, chunk);
            bytes += chunk;
            dataLen -= chunk;
        }
        return this;
    }

    typename TBase::Result Finish() override
    {
        if (!_initialised)
        {
            throw std::runtime_error("No data to hash.");
        }
        _initialised = false;

        typename TBase::Result result;
        TFinal(result.data(), &_ctx);
        return result;
    }
};

using AppleSha1Algorithm = AppleHashAlgorithm<Sha1Algorithm, CC_SHA1_CTX, CC_SHA1_Init, CC_SHA1_Update, CC_SHA1_Final>;
using AppleSha256Algorithm = AppleHashAlgorithm<
    Sha256Algorithm, CC_SHA256_CTX, CC_SHA256_Init, CC_SHA256_Update, CC_SHA256_Final>;

// Keys are kept as Security framework keys and exchanged as PKCS#1 PEM, the format OpenSSL's
// PEM_write_bio_RSAPrivateKey and PEM_write_bio_RSAPublicKey produce on other platforms.
class AppleRsaKey final : public RsaKey
{
public:
    SecKeyRef GetPrivateKey() const
    {
        return _privateKey.Get();
    }

    SecKeyRef GetPublicKey() const
    {
        return _publicKey.Get();
    }

    void Generate() override
    {
        int keySize = 2048;
        CFRef<CFNumberRef> keySizeNumber(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keySize));
        const void* keys[] = { kSecAttrKeyType, kSecAttrKeySizeInBits };
        const void* values[] = { kSecAttrKeyTypeRSA, keySizeNumber.Get() };
        CFRef<CFDictionaryRef> attributes(CFDictionaryCreate(
            kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

        CFErrorRef error{};
        auto privateKey = SecKeyCreateRandomKey(attributes.Get(), &error);
        if (privateKey == nullptr)
        {
            throw std::runtime_error("SecKeyCreateRandomKey failed: " + DescribeError(error));
        }
        _privateKey.Reset(privateKey);
        _publicKey.Reset(SecKeyCopyPublicKey(privateKey));
    }

    void SetPrivate(std::string_view pem) override
    {
        auto privateKey = CreateKey(ReadPEM(pem, kPrivateKeyBeginToken, kPrivateKeyEndToken), kSecAttrKeyClassPrivate);
        _privateKey.Reset(privateKey);
        _publicKey.Reset(SecKeyCopyPublicKey(privateKey));
    }

    void SetPublic(std::string_view pem) override
    {
        _privateKey.Reset();
        _publicKey.Reset(CreateKey(ReadPEM(pem, kPublicKeyBeginToken, kPublicKeyEndToken), kSecAttrKeyClassPublic));
    }

    std::string GetPrivate() override
    {
        return WritePEM(_privateKey.Get(), kPrivateKeyBeginToken, kPrivateKeyEndToken);
    }

    std::string GetPublic() override
    {
        return WritePEM(_publicKey.Get(), kPublicKeyBeginToken, kPublicKeyEndToken);
    }

private:
    static constexpr const char* kPublicKeyBeginToken = "-----BEGIN RSA PUBLIC KEY-----";
    static constexpr const char* kPublicKeyEndToken = "-----END RSA PUBLIC KEY-----";
    static constexpr const char* kPrivateKeyBeginToken = "-----BEGIN RSA PRIVATE KEY-----";
    static constexpr const char* kPrivateKeyEndToken = "-----END RSA PRIVATE KEY-----";
    static constexpr const char* kBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    CFRef<SecKeyRef> _privateKey;
    CFRef<SecKeyRef> _publicKey;

    static SecKeyRef CreateKey(const std::vector<uint8_t>& der, CFStringRef keyClass)
    {
        CFRef<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, der.data(), static_cast<CFIndex>(der.size())));
        const void* keys[] = { kSecAttrKeyType, kSecAttrKeyClass };
        const void* values[] = { kSecAttrKeyTypeRSA, keyClass };
        CFRef<CFDictionaryRef> attributes(CFDictionaryCreate(
            kCFAllocatorDefault, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

        CFErrorRef error{};
        auto key = SecKeyCreateWithData(data.Get(), attributes.Get(), &error);
        if (key == nullptr)
        {
            throw std::runtime_error("SecKeyCreateWithData failed: " + DescribeError(error));
        }
        return key;
    }

    static std::string WritePEM(SecKeyRef key, std::string_view beginToken, std::string_view endToken)
    {
        if (key == nullptr)
        {
            throw std::runtime_error("No key has been assigned");
        }

        // For RSA keys the external representation is PKCS#1 DER.
        CFErrorRef error{};
        CFRef<CFDataRef> data(SecKeyCopyExternalRepresentation(key, &error));
        if (data.Get() == nullptr)
        {
            throw std::runtime_error("SecKeyCopyExternalRepresentation failed: " + DescribeError(error));
        }

        auto b64 = EncodeBase64(ToVector(data.Get()));
        std::string result;
        result.append(beginToken).append("\n");
        for (size_t i = 0; i < b64.size(); i += 64)
        {
            result.append(b64, i, 64).append("\n");
        }
        result.append(endToken).append("\n");
        return result;
    }

    static std::vector<uint8_t> ReadPEM(std::string_view pem, std::string_view beginToken, std::string_view endToken)
    {
        auto beginPos = pem.find(beginToken);
        auto endPos = pem.find(endToken);
        if (beginPos == std::string_view::npos || endPos == std::string_view::npos || endPos < beginPos)
        {
            throw std::runtime_error("Invalid PEM file");
        }
        beginPos += beginToken.size();
        return DecodeBase64(pem.substr(beginPos, endPos - beginPos));
    }

    static std::string EncodeBase64(const std::vector<uint8_t>& input)
    {
        std::string result;
        result.reserve((input.size() + 2) / 3 * 4);
        for (size_t i = 0; i < input.size(); i += 3)
        {
            uint32_t n = input[i] << 16;
            if (i + 1 < input.size())
                n |= input[i + 1] << 8;
            if (i + 2 < input.size())
                n |= input[i + 2];
            result.push_back(kBase64Alphabet[(n >> 18) & 63]);
            result.push_back(kBase64Alphabet[(n >> 12) & 63]);
            result.push_back(i + 1 < input.size() ? kBase64Alphabet[(n >> 6) & 63] : '=');
            result.push_back(i + 2 < input.size() ? kBase64Alphabet[n & 63] : '=');
        }
        return result;
    }

    static std::vector<uint8_t> DecodeBase64(std::string_view input)
    {
        std::vector<uint8_t> result;
        uint32_t buffer{};
        int bits{};
        for (auto c : input)
        {
            int value;
            if (c >= 'A' && c <= 'Z')
                value = c - 'A';
            else if (c >= 'a' && c <= 'z')
                value = c - 'a' + 26;
            else if (c >= '0' && c <= '9')
                value = c - '0' + 52;
            else if (c == '+')
                value = 62;
            else if (c == '/')
                value = 63;
            else if (c == '=')
                break;
            else if (c == '\r' || c == '\n' || c == ' ' || c == '\t')
                continue;
            else
                throw std::runtime_error("Invalid base64 in PEM file");

            buffer = (buffer << 6) | value;
            bits += 6;
            if (bits >= 8)
            {
                bits -= 8;
                result.push_back(static_cast<uint8_t>(buffer >> bits));
            }
        }
        return result;
    }
};

class AppleRsaAlgorithm final : public RsaAlgorithm
{
public:
    std::vector<uint8_t> SignData(const RsaKey& key, const void* data, size_t dataLen) override
    {
        auto privateKey = static_cast<const AppleRsaKey&>(key).GetPrivateKey();
        if (privateKey == nullptr)
        {
            throw std::runtime_error("No private key has been assigned");
        }

        CFRef<CFDataRef> message(
            CFDataCreate(kCFAllocatorDefault, static_cast<const uint8_t*>(data), static_cast<CFIndex>(dataLen)));
        CFErrorRef error{};
        CFRef<CFDataRef> signature(
            SecKeyCreateSignature(privateKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, message.Get(), &error));
        if (signature.Get() == nullptr)
        {
            throw std::runtime_error("SecKeyCreateSignature failed: " + DescribeError(error));
        }
        return ToVector(signature.Get());
    }

    bool VerifyData(const RsaKey& key, const void* data, size_t dataLen, const void* sig, size_t sigLen) override
    {
        auto publicKey = static_cast<const AppleRsaKey&>(key).GetPublicKey();
        if (publicKey == nullptr)
        {
            throw std::runtime_error("No key has been assigned");
        }

        CFRef<CFDataRef> message(
            CFDataCreate(kCFAllocatorDefault, static_cast<const uint8_t*>(data), static_cast<CFIndex>(dataLen)));
        CFRef<CFDataRef> signature(
            CFDataCreate(kCFAllocatorDefault, static_cast<const uint8_t*>(sig), static_cast<CFIndex>(sigLen)));
        CFErrorRef error{};
        auto valid = SecKeyVerifySignature(
            publicKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, message.Get(), signature.Get(), &error);
        if (error != nullptr)
        {
            CFRelease(error);
        }
        return valid;
    }
};

namespace OpenRCT2::Crypt
{
    std::unique_ptr<Sha1Algorithm> CreateSHA1()
    {
        return std::make_unique<AppleSha1Algorithm>();
    }

    std::unique_ptr<Sha256Algorithm> CreateSHA256()
    {
        return std::make_unique<AppleSha256Algorithm>();
    }

    std::unique_ptr<RsaAlgorithm> CreateRSA()
    {
        return std::make_unique<AppleRsaAlgorithm>();
    }

    std::unique_ptr<RsaKey> CreateRSAKey()
    {
        return std::make_unique<AppleRsaKey>();
    }
} // namespace OpenRCT2::Crypt

    #pragma GCC diagnostic pop

#endif // DISABLE_NETWORK
