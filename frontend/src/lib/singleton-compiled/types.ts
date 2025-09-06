export interface CompiledContract {
  abi: any[];
  bytecode: string;
  contractName: string;
  name: string;
  description: string;
  entryPoint: string;
}

export interface SingletonPaymasterContracts {
  v6?: CompiledContract;
  v7: CompiledContract;
  v8?: CompiledContract;
}
