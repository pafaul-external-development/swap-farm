const { loadDefaultContaracts } = require("../../utils/loadDefaultContract");

async function main() {
    let contracts = await loadDefaultContaracts(false);

    console.log(await contracts.farmContract.fetchInfo());
}

main().then(
    () => process.exit(0)
).catch(
    (err) => {
        console.log(err);
        process.exit(1);
    }
)