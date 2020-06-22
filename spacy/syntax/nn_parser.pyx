# cython: infer_types=True, cdivision=True, boundscheck=False
cimport cython.parallel
cimport numpy as np
from itertools import islice
from cpython.ref cimport PyObject, Py_XDECREF
from cpython.exc cimport PyErr_CheckSignals, PyErr_SetFromErrno
from libc.math cimport exp
from libcpp.vector cimport vector
from libc.string cimport memset, memcpy
from libc.stdlib cimport calloc, free
from cymem.cymem cimport Pool
from thinc.backends.linalg cimport Vec, VecVec

from thinc.api import chain, clone, Linear, list2array, NumpyOps, CupyOps, use_ops
from thinc.api import get_array_module, zero_init, set_dropout_rate
from itertools import islice
import srsly
import numpy.random
import numpy
import warnings

from ..tokens.doc cimport Doc
from ..typedefs cimport weight_t, class_t, hash_t
from ._parser_model cimport alloc_activations, free_activations
from ._parser_model cimport predict_states, arg_max_if_valid
from ._parser_model cimport WeightsC, ActivationsC, SizesC, cpu_log_loss
from ._parser_model cimport get_c_weights, get_c_sizes
from .stateclass cimport StateClass
from ._state cimport StateC
from .transition_system cimport Transition
from ..gold.example cimport Example

from ..util import link_vectors_to_models, create_default_optimizer, registry
from ..compat import copy_array
from ..errors import Errors, Warnings
from .. import util
from . import nonproj


cdef class Parser:
    """
    Base class of the DependencyParser and EntityRecognizer.
    """
    name = 'base_parser'


    def __init__(self, Vocab vocab, model, **cfg):
        """Create a Parser.

        vocab (Vocab): The vocabulary object. Must be shared with documents
            to be processed. The value is set to the `.vocab` attribute.
        **cfg: Configuration parameters. Set to the `.cfg` attribute.
             If it doesn't include a value for 'moves',  a new instance is
             created with `self.TransitionSystem()`. This defines how the
             parse-state is created, updated and evaluated.
        """
        self.vocab = vocab
        moves = cfg.get("moves", None)
        if moves is None:
            # defined by EntityRecognizer as a BiluoPushDown
            moves = self.TransitionSystem(self.vocab.strings)
        self.moves = moves
        self.model = model
        if self.moves.n_moves != 0:
            self.set_output(self.moves.n_moves)
        self.cfg = cfg
        self._multitasks = []
        for multitask in cfg.get("multitasks", []):
            self.add_multitask_objective(multitask)

        self._rehearsal_model = None

    @classmethod
    def from_nlp(cls, nlp, model, **cfg):
        return cls(nlp.vocab, model, **cfg)

    def __reduce__(self):
        return (Parser, (self.vocab, self.model), (self.moves, self.cfg))

    def __getstate__(self):
        return (self.moves, self.cfg)

    def __setstate__(self, state):
        moves, config = state
        self.moves = moves
        self.cfg = config

    @property
    def move_names(self):
        names = []
        for i in range(self.moves.n_moves):
            name = self.moves.move_name(self.moves.c[i].move, self.moves.c[i].label)
            # Explicitly removing the internal "U-" token used for blocking entities
            if name != "U-":
                names.append(name)
        return names

    @property
    def labels(self):
        class_names = [self.moves.get_class_name(i) for i in range(self.moves.n_moves)]
        return class_names

    @property
    def tok2vec(self):
        '''Return the embedding and convolutional layer of the model.'''
        return self.model.get_ref("tok2vec")

    @property
    def postprocesses(self):
        # Available for subclasses, e.g. to deprojectivize
        return []

    def add_label(self, label):
        resized = False
        for action in self.moves.action_types:
            added = self.moves.add_action(action, label)
            if added:
                resized = True
        if resized:
            self._resize()

    def _resize(self):
        self.model.attrs["resize_output"](self.model, self.moves.n_moves)
        if self._rehearsal_model not in (True, False, None):
            self._rehearsal_model.attrs["resize_output"](
                self._rehearsal_model, self.moves.n_moves
            )

    def add_multitask_objective(self, target):
        # Defined in subclasses, to avoid circular import
        raise NotImplementedError

    def init_multitask_objectives(self, get_examples, pipeline, **cfg):
        '''Setup models for secondary objectives, to benefit from multi-task
        learning. This method is intended to be overridden by subclasses.

        For instance, the dependency parser can benefit from sharing
        an input representation with a label prediction model. These auxiliary
        models are discarded after training.
        '''
        pass

    def use_params(self, params):
        # Can't decorate cdef class :(. Workaround.
        with self.model.use_params(params):
            yield

    def __call__(self, Doc doc):
        """Apply the parser or entity recognizer, setting the annotations onto
        the `Doc` object.

        doc (Doc): The document to be processed.
        """
        states = self.predict([doc])
        self.set_annotations([doc], states, tensors=None)
        return doc

    def pipe(self, docs, int batch_size=256, int n_threads=-1):
        """Process a stream of documents.

        stream: The sequence of documents to process.
        batch_size (int): Number of documents to accumulate into a working set.
        YIELDS (Doc): Documents, in order.
        """
        cdef Doc doc
        for batch in util.minibatch(docs, size=batch_size):
            batch_in_order = list(batch)
            by_length = sorted(batch, key=lambda doc: len(doc))
            for subbatch in util.minibatch(by_length, size=max(batch_size//4, 2)):
                subbatch = list(subbatch)
                parse_states = self.predict(subbatch)
                self.set_annotations(subbatch, parse_states, tensors=None)
            yield from batch_in_order

    def predict(self, docs):
        if isinstance(docs, Doc):
            docs = [docs]
        if not any(len(doc) for doc in docs):
            result = self.moves.init_batch(docs)
            self._resize()
            return result
        return self.greedy_parse(docs, drop=0.0)

    def greedy_parse(self, docs, drop=0.):
        cdef vector[StateC*] states
        cdef StateClass state
        set_dropout_rate(self.model, drop)
        batch = self.moves.init_batch(docs)
        # This is pretty dirty, but the NER can resize itself in init_batch,
        # if labels are missing. We therefore have to check whether we need to
        # expand our model output.
        self._resize()
        model = self.model.predict(docs)
        weights = get_c_weights(model)
        for state in batch:
            if not state.is_final():
                states.push_back(state.c)
        sizes = get_c_sizes(model, states.size())
        with nogil:
            self._parseC(&states[0],
                weights, sizes)
        return batch

    cdef void _parseC(self, StateC** states,
            WeightsC weights, SizesC sizes) nogil:
        cdef int i, j
        cdef vector[StateC*] unfinished
        cdef ActivationsC activations = alloc_activations(sizes)
        while sizes.states >= 1:
            predict_states(&activations,
                states, &weights, sizes)
            # Validate actions, argmax, take action.
            self.c_transition_batch(states,
                activations.scores, sizes.classes, sizes.states)
            for i in range(sizes.states):
                if not states[i].is_final():
                    unfinished.push_back(states[i])
            for i in range(unfinished.size()):
                states[i] = unfinished[i]
            sizes.states = unfinished.size()
            unfinished.clear()
        free_activations(&activations)

    def set_annotations(self, docs, states, tensors=None):
        cdef StateClass state
        cdef Doc doc
        for i, (state, doc) in enumerate(zip(states, docs)):
            self.moves.finalize_state(state.c)
            for j in range(doc.length):
                doc.c[j] = state.c._sent[j]
            self.moves.finalize_doc(doc)
            for hook in self.postprocesses:
                hook(doc)

    def transition_states(self, states, float[:, ::1] scores):
        cdef StateClass state
        cdef float* c_scores = &scores[0, 0]
        cdef vector[StateC*] c_states
        for state in states:
            c_states.push_back(state.c)
        self.c_transition_batch(&c_states[0], c_scores, scores.shape[1], scores.shape[0])
        return [state for state in states if not state.c.is_final()]

    cdef void c_transition_batch(self, StateC** states, const float* scores,
            int nr_class, int batch_size) nogil:
        # n_moves should not be zero at this point, but make sure to avoid zero-length mem alloc
        with gil:
            assert self.moves.n_moves > 0
        is_valid = <int*>calloc(self.moves.n_moves, sizeof(int))
        cdef int i, guess
        cdef Transition action
        for i in range(batch_size):
            self.moves.set_valid(is_valid, states[i])
            guess = arg_max_if_valid(&scores[i*nr_class], is_valid, nr_class)
            if guess == -1:
                # This shouldn't happen, but it's hard to raise an error here,
                # and we don't want to infinite loop. So, force to end state.
                states[i].force_final()
            else:
                action = self.moves.c[guess]
                action.do(states[i], action.label)
                states[i].push_hist(guess)
        free(is_valid)

    def update(self, examples, drop=0., set_annotations=False, sgd=None, losses=None):
        # TODO:  This is just here for debugging, remove later.
        for eg in examples:
            oracle_seq = self.moves.get_oracle_sequence(eg)
        if losses is None:
            losses = {}
        losses.setdefault(self.name, 0.)
        for multitask in self._multitasks:
            multitask.update(examples, drop=drop, sgd=sgd)
        set_dropout_rate(self.model, drop)
        # Prepare the stepwise model, and get the callback for finishing the batch
        model, backprop_tok2vec = self.model.begin_update(
            [eg.predicted for eg in examples])
        states, golds, max_steps = self.moves.init_gold_batch(examples)
        all_states = list(states)
        states_golds = zip(states, golds)
        for _ in range(max_steps):
            if not states_golds:
                break
            states, golds = zip(*states_golds)
            scores, backprop = model.begin_update(states)
            d_scores = self.get_batch_loss(states, golds, scores, losses)
            backprop(d_scores)
            # Follow the predicted action
            self.transition_states(states, scores)
            states_golds = [(s, g) for (s, g) in zip(states, golds) if not s.is_final()]
        backprop_tok2vec(golds)
        if sgd is not None:
            self.model.finish_update(sgd)
        if set_annotations:
            docs = [eg.predicted for eg in examples]
            self.set_annotations(docs, all_states)
        return losses

    def rehearse(self, examples, sgd=None, losses=None, **cfg):
        """Perform a "rehearsal" update, to prevent catastrophic forgetting."""
        if losses is None:
            losses = {}
        for multitask in self._multitasks:
            if hasattr(multitask, 'rehearse'):
                multitask.rehearse(examples, losses=losses, sgd=sgd)
        if self._rehearsal_model is None:
            return None
        losses.setdefault(self.name, 0.)

        docs = [eg.predicted for eg in examples]
        states = self.moves.init_batch(docs)
        # This is pretty dirty, but the NER can resize itself in init_batch,
        # if labels are missing. We therefore have to check whether we need to
        # expand our model output.
        self._resize()
        # Prepare the stepwise model, and get the callback for finishing the batch
        set_dropout_rate(self._rehearsal_model, 0.0)
        set_dropout_rate(self.model, 0.0)
        tutor, _ = self._rehearsal_model.begin_update(docs)
        model, finish_update = self.model.begin_update(docs)
        n_scores = 0.
        loss = 0.
        while states:
            targets, _ = tutor.begin_update(states)
            guesses, backprop = model.begin_update(states)
            d_scores = (guesses - targets) / targets.shape[0]
            # If all weights for an output are 0 in the original model, don't
            # supervise that output. This allows us to add classes.
            loss += (d_scores**2).sum()
            backprop(d_scores, sgd=sgd)
            # Follow the predicted action
            self.transition_states(states, guesses)
            states = [state for state in states if not state.is_final()]
            n_scores += d_scores.size
        # Do the backprop
        finish_update(docs)
        if sgd is not None:
            self.model.finish_update(sgd)
        losses[self.name] += loss / n_scores
        return losses

    def get_gradients(self):
        """Get non-zero gradients of the model's parameters, as a dictionary
        keyed by the parameter ID. The values are (weights, gradients) tuples.
        """
        gradients = {}
        queue = [self.model]
        seen = set()
        for node in queue:
            if node.id in seen:
                continue
            seen.add(node.id)
            if hasattr(node, "_mem") and node._mem.gradient.any():
                gradients[node.id] = [node._mem.weights, node._mem.gradient]
            if hasattr(node, "_layers"):
                queue.extend(node._layers)
        return gradients

    def get_batch_loss(self, states, golds, float[:, ::1] scores, losses):
        cdef StateClass state
        cdef Pool mem = Pool()
        cdef int i

        # n_moves should not be zero at this point, but make sure to avoid zero-length mem alloc
        assert self.moves.n_moves > 0

        is_valid = <int*>mem.alloc(self.moves.n_moves, sizeof(int))
        costs = <float*>mem.alloc(self.moves.n_moves, sizeof(float))
        cdef np.ndarray d_scores = numpy.zeros((len(states), self.moves.n_moves),
                                        dtype='f', order='C')
        c_d_scores = <float*>d_scores.data
        unseen_classes = self.model.attrs["unseen_classes"]
        for i, (state, gold) in enumerate(zip(states, golds)):
            memset(is_valid, 0, self.moves.n_moves * sizeof(int))
            memset(costs, 0, self.moves.n_moves * sizeof(float))
            self.moves.set_costs(is_valid, costs, state, gold)
            for j in range(self.moves.n_moves):
                if costs[j] <= 0.0 and j in unseen_classes:
                    unseen_classes.remove(j)
            cpu_log_loss(c_d_scores,
                costs, is_valid, &scores[i, 0], d_scores.shape[1])
            c_d_scores += d_scores.shape[1]
        if len(states):
            d_scores /= len(states)
        if losses is not None:
            losses.setdefault(self.name, 0.)
            losses[self.name] += (d_scores**2).sum()
        return d_scores

    def create_optimizer(self):
        return create_default_optimizer()

    def set_output(self, nO):
        self.model.attrs["resize_output"](self.model, nO)

    def begin_training(self, get_examples, pipeline=None, sgd=None, **kwargs):
        self.cfg.update(kwargs)
        if len(self.vocab.lookups.get_table("lexeme_norm", {})) == 0:
            warnings.warn(Warnings.W033.format(model="parser or NER"))
        if not hasattr(get_examples, '__call__'):
            gold_tuples = get_examples
            get_examples = lambda: gold_tuples
        actions = self.moves.get_actions(
            examples=get_examples(),
            min_freq=self.cfg['min_action_freq'],
            learn_tokens=self.cfg["learn_tokens"]
        )
        for action, labels in self.moves.labels.items():
            actions.setdefault(action, {})
            for label, freq in labels.items():
                if label not in actions[action]:
                    actions[action][label] = freq
        self.moves.initialize_actions(actions)
        # make sure we resize so we have an appropriate upper layer
        self._resize()
        if sgd is None:
            sgd = self.create_optimizer()
        doc_sample = []
        for example in islice(get_examples(), 10):
            doc_sample.append(example.predicted)

        if pipeline is not None:
            for name, component in pipeline:
                if component is self:
                    break
                if hasattr(component, "pipe"):
                    doc_sample = list(component.pipe(doc_sample))
                else:
                    doc_sample = [component(doc) for doc in doc_sample]
        if doc_sample:
            self.model.initialize(doc_sample)
        else:
            self.model.initialize()
        if pipeline is not None:
            self.init_multitask_objectives(get_examples, pipeline, sgd=sgd, **self.cfg)
        link_vectors_to_models(self.vocab)
        return sgd

    def to_disk(self, path, exclude=tuple(), **kwargs):
        serializers = {
            'model': lambda p: (self.model.to_disk(p) if self.model is not True else True),
            'vocab': lambda p: self.vocab.to_disk(p),
            'moves': lambda p: self.moves.to_disk(p, exclude=["strings"]),
            'cfg': lambda p: srsly.write_json(p, self.cfg)
        }
        exclude = util.get_serialization_exclude(serializers, exclude, kwargs)
        util.to_disk(path, serializers, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        deserializers = {
            'vocab': lambda p: self.vocab.from_disk(p),
            'moves': lambda p: self.moves.from_disk(p, exclude=["strings"]),
            'cfg': lambda p: self.cfg.update(srsly.read_json(p)),
            'model': lambda p: None,
        }
        exclude = util.get_serialization_exclude(deserializers, exclude, kwargs)
        util.from_disk(path, deserializers, exclude)
        if 'model' not in exclude:
            path = util.ensure_path(path)
            with (path / 'model').open('rb') as file_:
                bytes_data = file_.read()
            try:
                self._resize()
                self.model.from_bytes(bytes_data)
            except AttributeError:
                raise ValueError(Errors.E149)
        return self

    def to_bytes(self, exclude=tuple(), **kwargs):
        serializers = {
            "model": lambda: (self.model.to_bytes()),
            "vocab": lambda: self.vocab.to_bytes(),
            "moves": lambda: self.moves.to_bytes(exclude=["strings"]),
            "cfg": lambda: srsly.json_dumps(self.cfg, indent=2, sort_keys=True)
        }
        exclude = util.get_serialization_exclude(serializers, exclude, kwargs)
        return util.to_bytes(serializers, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        deserializers = {
            "vocab": lambda b: self.vocab.from_bytes(b),
            "moves": lambda b: self.moves.from_bytes(b, exclude=["strings"]),
            "cfg": lambda b: self.cfg.update(srsly.json_loads(b)),
            "model": lambda b: None,
        }
        exclude = util.get_serialization_exclude(deserializers, exclude, kwargs)
        msg = util.from_bytes(bytes_data, deserializers, exclude)
        if 'model' not in exclude:
            if 'model' in msg:
                try:
                    self.model.from_bytes(msg['model'])
                except AttributeError:
                    raise ValueError(Errors.E149)
        return self
