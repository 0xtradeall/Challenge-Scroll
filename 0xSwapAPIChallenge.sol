import { config as dotenv } from "dotenv";
import {
  createWalletClient,
  http,
  getContract,
  erc20Abi,
  parseUnits,
  maxUint256,
  publicActions,
  concat,
  numberToHex,
  size,
} from "viem";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { scroll } from "viem/chains";
import { wethAbi } from "./abi/weth-abi";

dotenv(); // Load environment variables

const { PRIVATE_KEY, ZERO_EX_API_KEY, ALCHEMY_HTTP_TRANSPORT_URL } = process.env;

// Validate environment variables
if (!PRIVATE_KEY) throw new Error("Missing PRIVATE_KEY.");
if (!ZERO_EX_API_KEY) throw new Error("Missing ZERO_EX_API_KEY.");
if (!ALCHEMY_HTTP_TRANSPORT_URL) throw new Error("Missing ALCHEMY_HTTP_TRANSPORT_URL.");

// Set up headers for API requests
const headers = new Headers({
  "Content-Type": "application/json",
  "0x-api-key": ZERO_EX_API_KEY,
  "0x-version": "v2",
});

// Setup wallet client
const client = createWalletClient({
  account: privateKeyToAccount(`0x${PRIVATE_KEY}` as `0x${string}`),
  chain: scroll,
  transport: http(ALCHEMY_HTTP_TRANSPORT_URL),
}).extend(publicActions);

const [address] = await client.getAddresses(); // Get wallet address

// Set up contracts
const weth = getContract({
  address: "0x5300000000000000000000000000000000000004",
  abi: wethAbi,
  client,
});
const wsteth = getContract({
  address: "0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32",
  abi: erc20Abi,
  client,
});

// Function to display the percentage breakdown of liquidity sources
function displayLiquiditySources(route: any) {
  const totalBps = route.fills.reduce((acc: number, fill: any) => acc + parseInt(fill.proportionBps), 0);
  console.log(`${route.fills.length} Sources`);
  route.fills.forEach((fill: any) => {
    const percentage = (parseInt(fill.proportionBps) / 100).toFixed(2);
    console.log(`${fill.source}: ${percentage}%`);
  });
}

// Function to display the buy/sell taxes for tokens
function displayTokenTaxes(tokenMetadata: any) {
  const formatTax = (taxBps: string) => (parseInt(taxBps) / 100).toFixed(2);
  const buyTokenBuyTax = formatTax(tokenMetadata.buyToken.buyTaxBps);
  const buyTokenSellTax = formatTax(tokenMetadata.buyToken.sellTaxBps);
  const sellTokenBuyTax = formatTax(tokenMetadata.sellToken.buyTaxBps);
  const sellTokenSellTax = formatTax(tokenMetadata.sellToken.sellTaxBps);

  if (buyTokenBuyTax > 0 || buyTokenSellTax > 0) {
    console.log(`Buy Token Buy Tax: ${buyTokenBuyTax}%`);
    console.log(`Buy Token Sell Tax: ${buyTokenSellTax}%`);
  }

  if (sellTokenBuyTax > 0 || sellTokenSellTax > 0) {
    console.log(`Sell Token Buy Tax: ${sellTokenBuyTax}%`);
    console.log(`Sell Token Sell Tax: ${sellTokenSellTax}%`);
  }
}

// Function to fetch and display all liquidity sources on Scroll
const getLiquiditySources = async () => {
  const chainId = client.chain.id.toString(); // Ensure correct chain ID for Scroll
  const sourcesParams = new URLSearchParams({ chainId });
  const sourcesResponse = await fetch(`https://api.0x.org/swap/v1/sources?${sourcesParams.toString()}`, { headers });
  const sourcesData = await sourcesResponse.json();
  const sources = Object.keys(sourcesData.sources);
  console.log("Liquidity sources for Scroll chain:");
  console.log(sources.join(", "));
};

const main = async () => {
  await getLiquiditySources(); // Display all liquidity sources

  // Specify sell amount
  const decimals = await weth.read.decimals() as number;
  const sellAmount = parseUnits("0.1", decimals);

  // Set parameters for monetization
  const affiliateFeeBps = "100"; // 1%
  const surplusCollection = "true";

  // Fetch price with monetization parameters
  const priceParams = new URLSearchParams({
    chainId: client.chain.id.toString(),
    sellToken: weth.address,
    buyToken: wsteth.address,
    sellAmount: sellAmount.toString(),
    taker: client.account.address,
    affiliateFee: affiliateFeeBps,
    surplusCollection,
  });

  const priceResponse = await fetch("https://api.0x.org/swap/permit2/price?" + priceParams.toString(), { headers });
  const price = await priceResponse.json();
  console.log("Fetching price to swap 0.1 WETH for wstETH");
  console.log(`https://api.0x.org/swap/permit2/price?${priceParams.toString()}`);
  console.log("priceResponse: ", price);

  // Check if taker needs to set an allowance for Permit2
  if (price.issues.allowance !== null) {
    try {
      const { request } = await weth.simulate.approve([price.issues.allowance.spender, maxUint256]);
      console.log("Approving Permit2 to spend WETH...", request);
      const hash = await weth.write.approve(request.args); // Set approval
      console.log("Approved Permit2 to spend WETH.", await client.waitForTransactionReceipt({ hash }));
    } catch (error) {
      console.log("Error approving Permit2:", error);
    }
  } else {
    console.log("WETH already approved for Permit2");
  }

  // Fetch quote with monetization parameters
  const quoteParams = new URLSearchParams(priceParams);
  const quoteResponse = await fetch("https://api.0x.org/swap/permit2/quote?" + quoteParams.toString(), { headers });
  const quote = await quoteResponse.json();
  console.log("Fetching quote to swap 0.1 WETH for wstETH");
  console.log("quoteResponse: ", quote);

  // Display liquidity sources breakdown
  if (quote.route) {
    displayLiquiditySources(quote.route);
  }

  // Display token buy/sell taxes
  if (quote.tokenMetadata) {
    displayTokenTaxes(quote.tokenMetadata);
  }

  // Display affiliate fee and trade surplus
  if (quote.affiliateFeeBps) {
    const affiliateFee = (parseInt(quote.affiliateFeeBps) / 100).toFixed(2);
    console.log(`Affiliate Fee: ${affiliateFee}%`);
  }

  if (quote.tradeSurplus && parseFloat(quote.tradeSurplus) > 0) {
    console.log(`Trade Surplus Collected: ${quote.tradeSurplus}`);
  }

  // Sign permit2.eip712 returned from quote
  let signature: Hex | undefined;
  if (quote.permit2?.eip712) {
    try {
      signature = await client.signTypedData(quote.permit2.eip712);
      console.log("Signed permit2 message from quote response");
    } catch (error) {
      console.error("Error signing permit2 coupon:", error);
    }

    // Append signature to transaction data
    if (signature && quote?.transaction?.data) {
      const signatureLengthInHex = numberToHex(size(signature), { signed: false, size: 32 });
      const transactionData = quote.transaction.data as Hex;
      const sigLengthHex = signatureLengthInHex as Hex;
      const sig = signature as Hex;
      quote.transaction.data = concat([transactionData, sigLengthHex, sig]);
    } else {
      throw new Error("Failed to obtain signature or transaction data");
    }
  }

  // Submit transaction with permit2 signature
  if (signature && quote.transaction.data) {
    const nonce = await client.getTransactionCount({ address: client.account.address });
    const signedTransaction = await client.signTransaction({
      account: client.account,
      chain: client.chain,
      gas: quote?.transaction.gas ? BigInt(quote.transaction.gas) : undefined,
      to: quote?.transaction.to,
      data: quote.transaction.data,
      value: quote?.transaction.value ? BigInt(quote.transaction.value) : undefined,
      gasPrice: quote?.transaction.gasPrice ? BigInt(quote.transaction.gasPrice) : undefined,
      nonce,
    });
    const hash = await client.sendRawTransaction({ serializedTransaction: signedTransaction });
    console.log("Transaction hash:", hash);
    console.log(`See tx details at https://scrollscan.com/tx/${hash}`);
  } else {
    console.error("Failed to obtain a signature, transaction not sent.");
  }
};

main();
