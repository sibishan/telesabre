#!/usr/bin/env python3
#
# Decompose a QASM circuit down to 1- and 2-qubit gates and write it back out
# as OPENQASM 2.0, which is the only dialect the C parser in src/circuit.c
# understands (it looks for `qreg name[N];` declarations).
#
# Usage:
#   scripts/decompose.py <input.qasm|dir> [more ...] -o <out.qasm|out_dir>
#   scripts/decompose.py <input.qasm|dir> [more ...] --in-place
#
# Example:
#   scripts/decompose.py circuits/qasm_100 -o circuits/qasm_100_dec -v

import argparse
import os
import sys

from qiskit import QuantumCircuit, qasm2, qasm3
from qiskit.converters import circuit_to_dag
from qiskit.transpiler import PassManager
from qiskit.transpiler.passes import (
    OptimizeSwapBeforeMeasure,
    RemoveDiagonalGatesBeforeMeasure,
    Unroll3qOrMore,
    RemoveResetInZeroState,
    RemoveBarriers,
    Decompose,
)


def get_non_single_qg_names(non_single_qg):
    non_single_qg_names = set()

    for gate in non_single_qg:
        if gate.name == "cx":
            continue

        non_single_qg_names.add(gate.name)

    return list(non_single_qg_names)


def init_circuit(qc, verbose=False):
    dag = circuit_to_dag(qc)

    two_qg_list = dag.two_qubit_ops()
    mul_qg_list = dag.multi_qubit_ops()

    non_single_qg_names = get_non_single_qg_names(
        two_qg_list + mul_qg_list
    )

    if verbose:
        if non_single_qg_names:
            print(f"GATES TO DECOMPOSE: {non_single_qg_names}")
        else:
            print("NO GATES TO DECOMPOSE")

    init_pm = PassManager()

    init_pm.append([
        Unroll3qOrMore(),
        RemoveResetInZeroState(),
        OptimizeSwapBeforeMeasure(),
        RemoveDiagonalGatesBeforeMeasure(),
        RemoveBarriers(),
    ])

    if non_single_qg_names:
        init_pm.append(
            Decompose(non_single_qg_names)
        )

    init_cir = init_pm.run(qc)

    return init_cir

def qasm_version(path):
    # MQT Bench puts a comment banner ahead of the version line, so scan for it
    # rather than sniffing a fixed-size chunk of the header.
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("OPENQASM"):
                return line.split()[1].split(".")[0]

    return None


def load_qasm(path):
    version = qasm_version(path)

    if version == "3":
        return qasm3.load(path)

    if version == "2":
        return QuantumCircuit.from_qasm_file(path)

    raise ValueError(f"Unsupported OpenQASM version: {path}")



def check_decomposed(qc, path):
    # src/circuit.c stores at most 2 target qubits per gate, so anything wider
    # would be silently truncated by the C parser.
    for instruction in qc.data:
        if instruction.operation.name in ("barrier", "measure"):
            continue
        if len(instruction.qubits) > 2:
            raise ValueError(
                f"{path}: {instruction.operation.name} still acts on "
                f"{len(instruction.qubits)} qubits after decomposition"
            )


def dump_qasm2(qc, path):
    # The C parser derives num_qubits purely from the `qreg` lines, so a
    # register-less export would make it read an empty circuit.
    text = qasm2.dumps(qc)
    if "\nqreg " not in "\n" + text:
        raise ValueError(f"{path}: QASM 2.0 export contains no qreg declaration")

    with open(path, "w") as f:
        f.write(text)
        if not text.endswith("\n"):
            f.write("\n")


def decompose_file(src, dst, verbose=False):
    qc = load_qasm(src)
    before = dict(qc.count_ops())

    dec = init_circuit(qc, verbose=verbose)
    check_decomposed(dec, src)

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    dump_qasm2(dec, dst)

    if verbose:
        print(f"  before: {before}")
        print(f"  after:  {dict(dec.count_ops())}")

    return dec


def collect_inputs(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            files += sorted(
                os.path.join(path, name)
                for name in os.listdir(path)
                if name.endswith(".qasm")
            )
        else:
            files.append(path)
    return files


def main():
    parser = argparse.ArgumentParser(
        description="Decompose QASM circuits to 1-/2-qubit gates and emit OPENQASM 2.0."
    )
    parser.add_argument("inputs", nargs="+", help=".qasm files or directories of them")
    parser.add_argument(
        "-o", "--output",
        help="output file (single input) or output directory",
    )
    parser.add_argument(
        "--in-place", action="store_true",
        help="overwrite each input file with its decomposed version",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if args.in_place == bool(args.output):
        parser.error("pass exactly one of -o/--output or --in-place")

    files = collect_inputs(args.inputs)
    if not files:
        parser.error("no .qasm files found in the given inputs")

    # A lone -o naming a file is only meaningful for a single input.
    output_is_dir = (
        args.output is not None
        and (len(files) > 1 or os.path.isdir(args.output) or not args.output.endswith(".qasm"))
    )

    failed = 0
    for src in files:
        if args.in_place:
            dst = src
        elif output_is_dir:
            dst = os.path.join(args.output, os.path.basename(src))
        else:
            dst = args.output

        print(f"{src} -> {dst}")
        try:
            decompose_file(src, dst, verbose=args.verbose)
        except Exception as error:
            print(f"  FAILED: {error}", file=sys.stderr)
            failed += 1

    print(f"Decomposed {len(files) - failed}/{len(files)} circuit(s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
