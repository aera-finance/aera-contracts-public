// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

////////////////////////////////////////////////////////////
//                    Memory & Calldata                   //
////////////////////////////////////////////////////////////

// Size of a word in bytes
uint256 constant WORD_SIZE = 32;

// Size of a function selector in bytes
uint256 constant SELECTOR_SIZE = 4;

// Minimum valid calldata size (selector + one word = 36)
uint256 constant MINIMUM_CALLDATA_LENGTH = WORD_SIZE + SELECTOR_SIZE;

// Offset to skip selector and first word in calldata
uint256 constant CALLDATA_OFFSET = MINIMUM_CALLDATA_LENGTH;

// Offset for extracting spender address from approval calldata
uint256 constant ERC20_SPENDER_OFFSET = 36;

// Size of an address in bits
uint256 constant ADDRESS_SIZE_BITS = 160;

////////////////////////////////////////////////////////////
//                     Hooks Constants                    //
////////////////////////////////////////////////////////////

// Mask for a bit indicating whether a hooks has before submit call
uint256 constant BEFORE_HOOK_MASK = 1;

// Mask for a bit indicating whether a hooks has after submit call
uint256 constant AFTER_HOOK_MASK = 2;

// Mask for a bit indicating whether a hooks exists
uint256 constant HOOKS_FLAG_MASK = 0x80;

// Mask for 7 bits indicating the number of configurable hooks offsets
uint256 constant CONFIGURABLE_HOOKS_LENGTH_MASK = 0x7F;

////////////////////////////////////////////////////////////
//                     Bit Operations                     //
////////////////////////////////////////////////////////////

// Mask for extracting 8-bit values
uint256 constant MASK_8_BIT = 0xff;

// Mask for extracting 16-bit values
uint256 constant MASK_16_BIT = 0xffff;

////////////////////////////////////////////////////////////
//                    Pipeline Constants                  //
////////////////////////////////////////////////////////////

// Bit offset for results index in packed clipboard data
uint256 constant RESULTS_INDEX_OFFSET = 24;

// Bit offset for copy word position in packed clipboard data
uint256 constant COPY_WORD_OFFSET = 16;

////////////////////////////////////////////////////////////
//                   Extractor Constants                  //
////////////////////////////////////////////////////////////

// Number of bits per extraction offset
uint256 constant EXTRACT_OFFSET_SIZE_BITS = 16;

// Number of bits to shift to get the offset (256 - 16)
uint256 constant EXTRACTION_OFFSET_SHIFT_BITS = 240;

/// @dev Maximum number of extraction offsets(16) + 1
uint256 constant MAX_EXTRACT_OFFSETS_EXCLUSIVE = 17;

////////////////////////////////////////////////////////////
//                   Callback Constants                   //
////////////////////////////////////////////////////////////

// Maximum value for uint16, used to indicate no callback data
uint16 constant NO_CALLBACK_DATA = type(uint16).max;

// Offset for selector in callback data
uint256 constant SELECTOR_OFFSET = 48;

// Offset for callback data
uint256 constant CALLBACK_DATA_OFFSET = 160;

////////////////////////////////////////////////////////////
//                   Fee Constants                        //
////////////////////////////////////////////////////////////

// Basis points denominator (100%)
uint256 constant ONE_IN_BPS = 1e4;

// Maximum TVL fee
uint256 constant MAX_TVL_FEE = 2000; // 20%

// Maximum performance fee
uint256 constant MAX_PERFORMANCE_FEE = ONE_IN_BPS;

// Seconds in a year for fee calculations
uint256 constant SECONDS_PER_YEAR = 365 days;

// Maximum dispute period
uint256 constant MAX_DISPUTE_PERIOD = 30 days;

////////////////////////////////////////////////////////////
//                   Unit Price Constants                //
////////////////////////////////////////////////////////////

/// @dev Precision for unit price calculations (18 decimals)
uint256 constant UNIT_PRICE_PRECISION = 1e18;

/// @dev One minute in seconds
uint256 constant ONE_MINUTE = 1 minutes;

/// @dev One day in seconds
uint256 constant ONE_DAY = 1 days;

////////////////////////////////////////////////////////////
//                   Provisioner Constants                //
////////////////////////////////////////////////////////////

/// @dev Minimum multiplier 50% (applies to all deposit and redeem multipliers)
uint256 constant MIN_MULTIPLIER = 5000;

/// @dev Deposit/Redeem flag in RequestType enum
uint256 constant DEPOSIT_REDEEM_FLAG = 1;

/// @dev Auto/Fixed price flag in RequestType enum
uint256 constant AUTO_PRICE_FIXED_PRICE_FLAG = 2;

/// @dev One unit with 18 decimals
uint256 constant ONE_UNIT = 1e18;

/// @dev Maximum seconds between request deadline and current timestamp
uint256 constant MAX_SECONDS_TO_DEADLINE = 365 days;

/// @dev Upper bound for depositRefundTimeout to prevent indefinite user lockout
uint256 constant MAX_DEPOSIT_REFUND_TIMEOUT = 30 days;

////////////////////////////////////////////////////////////
//                   Whitelist Constants                  //
////////////////////////////////////////////////////////////

/// @dev Whitelist flag in AddressToUintMap
uint8 constant IS_WHITELISTED_FLAG = 1;
