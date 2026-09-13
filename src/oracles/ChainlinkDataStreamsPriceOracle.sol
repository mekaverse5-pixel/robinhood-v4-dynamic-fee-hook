// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReferencePriceOracle} from "../interfaces/IReferencePriceOracle.sol";

interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}

/// @notice Authenticated Chainlink Data Streams v4 report adapter for one feed.
/// @dev Anyone may submit a signed report. The immutable verifier authenticates
///      it; the hook independently enforces staleness, market status and deviation.
contract ChainlinkDataStreamsPriceOracle is IReferencePriceOracle {
    struct ReportV4 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        uint32 marketStatus;
    }

    IVerifierProxy public immutable verifier;
    bytes32 public immutable feedId;
    uint8 public immutable feedDecimals;
    bool public immutable requireMarketOpen;

    uint256 private latestPrice;
    uint256 private latestTimestamp;
    bool private latestMarketOpen;
    bool private submitting;

    error InvalidVerifier();
    error InvalidFeed();
    error InvalidReport();
    error InvalidPrice();
    error ReportExpired();
    error OlderReport();
    error ReentrantSubmission();

    event ReportAccepted(bytes32 indexed feedId, uint256 priceX18, uint256 observationsTimestamp, bool marketOpen);

    constructor(address verifierProxy, bytes32 expectedFeedId, uint8 decimals, bool enforceMarketOpen) {
        if (verifierProxy.code.length == 0) revert InvalidVerifier();
        if (expectedFeedId == bytes32(0) || decimals > 18) revert InvalidFeed();
        verifier = IVerifierProxy(verifierProxy);
        feedId = expectedFeedId;
        feedDecimals = decimals;
        requireMarketOpen = enforceMarketOpen;
    }

    function submitReport(bytes calldata unverifiedReport) external payable {
        if (submitting) revert ReentrantSubmission();
        submitting = true;
        bytes memory verifiedReport = verifier.verify{value: msg.value}(unverifiedReport, bytes(""));
        submitting = false;

        ReportV4 memory report = abi.decode(verifiedReport, (ReportV4));
        if (report.feedId != feedId) revert InvalidFeed();
        if (report.price <= 0 || report.observationsTimestamp == 0) revert InvalidPrice();
        if (report.expiresAt < block.timestamp || report.validFromTimestamp > block.timestamp) revert ReportExpired();
        if (report.observationsTimestamp < latestTimestamp) revert OlderReport();

        uint256 normalizedPrice = uint256(uint192(report.price)) * (10 ** uint256(18 - feedDecimals));
        bool marketOpen = !requireMarketOpen || report.marketStatus == 2;
        latestPrice = normalizedPrice;
        latestTimestamp = report.observationsTimestamp;
        latestMarketOpen = marketOpen;
        emit ReportAccepted(feedId, normalizedPrice, report.observationsTimestamp, marketOpen);
    }

    function latestPriceX18() external view returns (uint256 priceX18, uint256 updatedAt, bool marketOpen) {
        return (latestPrice, latestTimestamp, latestMarketOpen);
    }
}
