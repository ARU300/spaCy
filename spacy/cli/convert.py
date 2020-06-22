from typing import Optional
from enum import Enum
from pathlib import Path
from wasabi import Printer
import srsly
import re

from ._app import app, Arg, Opt
from ..gold import docs_to_json
from ..tokens import DocBin
from ..gold.converters import iob2docs, conll_ner2docs, json2docs


# Converters are matched by file extension except for ner/iob, which are
# matched by file extension and content. To add a converter, add a new
# entry to this dict with the file extension mapped to the converter function
# imported from /converters.

CONVERTERS = {
    # "conllubio": conllu2docs, TODO
    # "conllu": conllu2docs, TODO
    # "conll": conllu2docs, TODO
    "ner": conll_ner2docs,
    "iob": iob2docs,
    "json": json2docs,
}


# File types that can be written to stdout
FILE_TYPES_STDOUT = ("json")


class FileTypes(str, Enum):
    json = "json"
    spacy = "spacy"


@app.command("convert")
def convert_cli(
    # fmt: off
    input_path: str = Arg(..., help="Input file or directory", exists=True),
    output_dir: Path = Arg("-", help="Output directory. '-' for stdout.", allow_dash=True, exists=True),
    file_type: FileTypes = Opt("spacy", "--file-type", "-t", help="Type of data to produce"),
    n_sents: int = Opt(1, "--n-sents", "-n", help="Number of sentences per doc (0 to disable)"),
    seg_sents: bool = Opt(False, "--seg-sents", "-s", help="Segment sentences (for -c ner)"),
    model: Optional[str] = Opt(None, "--model", "-b", help="Model for sentence segmentation (for -s)"),
    morphology: bool = Opt(False, "--morphology", "-m", help="Enable appending morphology to tags"),
    merge_subtokens: bool = Opt(False, "--merge-subtokens", "-T", help="Merge CoNLL-U subtokens"),
    converter: str = Opt("auto", "--converter", "-c", help=f"Converter: {tuple(CONVERTERS.keys())}"),
    ner_map: Optional[Path] = Opt(None, "--ner-map", "-N", help="NER tag mapping (as JSON-encoded dict of entity types)", exists=True),
    lang: Optional[str] = Opt(None, "--lang", "-l", help="Language (if tokenizer required)"),
    # fmt: on
):
    """
    Convert files into json or DocBin format for use with train command and other
    experiment management functions. If no output_dir is specified, the data
    is written to stdout, so you can pipe them forward to a JSON file:
    $ spacy convert some_file.conllu > some_file.json
    """
    if isinstance(file_type, FileTypes):
        # We get an instance of the FileTypes from the CLI so we need its string value
        file_type = file_type.value
    cli_args = locals()
    silent = output_dir == "-"
    output_dir = Path(output_dir) if output_dir != "-" else "-"
    msg = Printer(no_print=silent)
    verify_cli_args(msg, **cli_args)
    convert(
        input_path,
        output_dir,
        file_type=file_type,
        n_sents=n_sents,
        seg_sents=seg_sents,
        model=model,
        morphology=morphology,
        merge_subtokens=merge_subtokens,
        converter=converter,
        ner_map=ner_map,
        lang=lang,
        silent=silent,
        msg=msg,
    )


def convert(
        input_path: Path,
        output_dir: Path,
        *,
        file_type: str = "json",
        n_sents: int = 1,
        seg_sents: bool = False,
        model: Optional[str] = None,
        morphology: bool = False,
        merge_subtokens: bool = False,
        converter: str = "auto",
        ner_map: Optional[Path] = None,
        lang: Optional[str] = None,
        silent: bool = True,
        msg: Optional[Path] = None,
) -> None:
    if not msg:
        msg = Printer(no_print=silent)
    ner_map = srsly.read_json(ner_map) if ner_map is not None else None

    for input_loc in walk_directory(input_path):
        input_data = input_loc.open("r", encoding="utf-8").read()
        # Use converter function to convert data
        func = CONVERTERS[converter]
        docs = func(
            input_data,
            n_sents=n_sents,
            seg_sents=seg_sents,
            append_morphology=morphology,
            merge_subtokens=merge_subtokens,
            lang=lang,
            model=model,
            no_print=silent,
            ner_map=ner_map,
        )
    if output_dir != "-":
        # Export data to a file
        suffix = f".{file_type}"
        subpath = input_loc.relative_to(input_path)
        output_file = Path(output_dir) / subpath.with_suffix(suffix)
        if not output_file.parent.exists():
            output_file.parent.mkdir(parents=True)
        if file_type == "json":
            srsly.write_json(output_file, docs_to_json(docs))
        else:
            data = DocBin(docs=docs).to_bytes()
            with output_file.open("wb") as file_:
                file_.write(data)
        msg.good(f"Generated output file ({len(docs)} documents): {output_file}")
    else:
        # Print to stdout
        if file_type == "json":
            srsly.write_json("-", docs)


def autodetect_ner_format(input_data: str) -> str:
    # guess format from the first 20 lines
    lines = input_data.split("\n")[:20]
    format_guesses = {"ner": 0, "iob": 0}
    iob_re = re.compile(r"\S+\|(O|[IB]-\S+)")
    ner_re = re.compile(r"\S+\s+(O|[IB]-\S+)$")
    for line in lines:
        line = line.strip()
        if iob_re.search(line):
            format_guesses["iob"] += 1
        if ner_re.search(line):
            format_guesses["ner"] += 1
    if format_guesses["iob"] == 0 and format_guesses["ner"] > 0:
        return "ner"
    if format_guesses["ner"] == 0 and format_guesses["iob"] > 0:
        return "iob"
    return None


def walk_directory(path):
    if not path.is_dir():
        return [path]
    paths = [path]
    locs = []
    seen = set()
    for path in paths:
        if str(path) in seen:
            continue
        seen.add(str(path))
        if path.parts[-1].startswith("."):
            continue
        elif path.is_dir():
            paths.extend(path.iterdir())
        else:
            locs.append(path)
    return locs


def verify_cli_args(
    msg,
    input_path,
    output_dir,
    file_type,
    n_sents,
    seg_sents,
    model,
    morphology,
    merge_subtokens,
    converter,
    ner_map,
    lang,
):
    if converter == "ner" or converter == "iob":
        input_data = input_path.open("r", encoding="utf-8").read()
        converter_autodetect = autodetect_ner_format(input_data)
        if converter_autodetect == "ner":
            msg.info("Auto-detected token-per-line NER format")
            converter = converter_autodetect
        elif converter_autodetect == "iob":
            msg.info("Auto-detected sentence-per-line NER format")
            converter = converter_autodetect
        else:
            msg.warn(
                "Can't automatically detect NER format. Conversion may not",
                "succeed. See https://spacy.io/api/cli#convert",
            )
    if file_type not in FILE_TYPES_STDOUT and output_dir == "-":
        # TODO: support msgpack via stdout in srsly?
        msg.fail(
            f"Can't write .{file_type} data to stdout",
            "Please specify an output directory.",
            exits=1,
        )
    if not input_path.exists():
        msg.fail("Input file not found", input_path, exits=1)
    if output_dir != "-" and not Path(output_dir).exists():
        msg.fail("Output directory not found", output_dir, exits=1)
    if input_path.is_dir():
        input_locs = walk_directory(input_path)
        if len(input_locs) == 0:
            msg.fail("No input files in directory", input_path, exits=1)
        file_types = list(set([loc.suffix[1:] for loc in input_locs]))
        if len(file_types) >= 2:
            file_types = ",".join(file_types)
            msg.fail("All input files must be same type", file_types, exits=1)
        if converter == "auto":
            converter = file_types[0]
    else:
        converter = input_path.suffix[1:]
    if converter not in CONVERTERS:
        msg.fail(f"Can't find converter for {converter}", exits=1)
    return converter


def _get_converter(msg, converter, input_path):
    if input_path.is_dir():
        input_path = walk_directory(input_path)[0]
    if converter == "auto":
        converter = input_path.suffix[1:]
    if converter == "ner" or converter == "iob":
        with input_path.open() as file_:
            input_data = file_.read()
        converter_autodetect = autodetect_ner_format(input_data)
        if converter_autodetect == "ner":
            msg.info("Auto-detected token-per-line NER format")
            converter = converter_autodetect
        elif converter_autodetect == "iob":
            msg.info("Auto-detected sentence-per-line NER format")
            converter = converter_autodetect
        else:
            msg.warn(
                "Can't automatically detect NER format. "
                "Conversion may not succeed. "
                "See https://spacy.io/api/cli#convert"
            )
    return converter
