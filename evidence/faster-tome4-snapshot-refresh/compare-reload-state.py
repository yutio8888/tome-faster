#!/usr/bin/env python3
"""Compare selected reload state with a bijective, schema-limited UID remap.

String lengths are UTF-8 bytes, and numeric/boolean keys remain distinct. Never
publish canonical values or the UID map. Unsupported/ambiguous identities and
unmapped UID references fail validation rather than being discarded.
"""
import argparse
import copy
from collections import defaultdict, Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import tempfile


@dataclass(frozen=True)
class Atom:
    kind: str
    value: str


def key(name):
    return Atom('s', name)


class Parser:
    def __init__(self, text):
        self.text = text.encode('utf-8')
        self.pos = 0

    def value(self):
        b, i = self.text, self.pos
        token = b[i:i + 1]
        if token == b'{':
            self.pos += 1
            table = {}
            if b[self.pos:self.pos + 1] == b'}':
                self.pos += 1
                return table
            while True:
                k = self.value()
                assert isinstance(k, Atom), 'unexpected nonscalar projected key'
                assert b[self.pos:self.pos + 1] == b'=', 'canonical assignment delimiter missing'
                self.pos += 1
                assert k not in table, 'duplicate canonical key'
                table[k] = self.value()
                delimiter = b[self.pos:self.pos + 1]
                self.pos += 1
                if delimiter == b'}':
                    return table
                assert delimiter == b';', 'canonical item delimiter missing'
        if token == b's':
            colon = b.index(b':', i + 1)
            length = int(b[i + 1:colon])
            end = colon + 1 + length
            assert end <= len(b), 'truncated UTF-8 canonical string'
            value = b[colon + 1:end].decode('utf-8')
            self.pos = end
            return Atom('s', value)
        if token == b'n' and b[i:i + 4] != b'nil:':
            end = i + 1
            while end < len(b) and b[end:end + 1] not in (b'=', b';', b'}'):
                end += 1
            value = b[i + 1:end].decode('ascii')
            assert re.fullmatch(r'-?(?:\d+(?:\.\d+)?(?:e[+-]?\d+)?|nan|inf)', value), 'invalid canonical number'
            self.pos = end
            return Atom('n', value)
        for literal in (b'boolean:true', b'boolean:false', b'nil:nil'):
            if b[i:i + len(literal)] == literal:
                self.pos += len(literal)
                kind, value = literal.decode('ascii').split(':')
                return Atom(kind, value)
        raise AssertionError('unsupported canonical token')

    def parse(self):
        out = self.value()
        assert self.pos == len(self.text), 'trailing canonical bytes'
        return out


def read(path):
    raw = json.loads(Path(path).read_text())
    parsed = {section: Parser(value).parse() for section, value in raw.items()}
    assert all(encode(parsed[section]).decode('utf-8') == value for section, value in raw.items()), 'canonical parse/re-encode mismatch'
    return raw, parsed


def encode(value):
    if isinstance(value, Atom):
        b = value.value.encode('utf-8')
        if value.kind == 's':
            return b's' + str(len(b)).encode('ascii') + b':' + b
        if value.kind == 'n':
            return b'n' + b
        return value.kind.encode('ascii') + b':' + b
    return b'{' + b';'.join(sorted(encode(k) + b'=' + encode(v) for k, v in value.items())) + b'}'


def component(atom):
    if atom.kind == 's':
        return '.' + atom.value if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', atom.value) else '[' + json.dumps(atom.value) + ']'
    if atom.kind == 'n':
        return '[' + atom.value + ']'
    return '[' + atom.kind + ':' + atom.value + ']'


def sortkey(atom):
    return atom.kind, atom.value


def key_types(sections):
    counts = Counter({'string': 0, 'number': 0, 'boolean': 0})
    def visit(value):
        if isinstance(value, Atom):
            return
        for k, child in value.items():
            counts[{'s': 'string', 'n': 'number'}.get(k.kind, k.kind)] += 1
            visit(child)
    for value in sections.values():
        visit(value)
    return dict(counts)


def differences(before, after, path, result):
    if isinstance(before, Atom) or isinstance(after, Atom):
        if before != after:
            result.append({'kind': 'changed', 'path': path})
        return
    for k in sorted(before.keys() | after.keys(), key=sortkey):
        child = path + component(k)
        if k not in before:
            result.append({'kind': 'added', 'path': child})
        elif k not in after:
            result.append({'kind': 'removed', 'path': child})
        else:
            differences(before[k], after[k], child, result)


def compare(expected_path, actual_path):
    raw_before, before = read(expected_path)
    raw_after, after = read(actual_path)
    actors_before = {section: state for section, state in before.items() if section.startswith('actor:')}
    actors_after = {section: state for section, state in after.items() if section.startswith('actor:')}
    for actors in (actors_before, actors_after):
        assert all(state[key('uid')] == Atom('n', section.split(':', 1)[1]) for section, state in actors.items()), 'section UID differs from entity UID field'
    def signature(state, game):
        return (state.get(key('uid')) == game.get(key('player_uid')),
                *(state.get(key(name)) for name in ('__CLASSNAME', 'x', 'y', 'player')))
    groups_before, groups_after = defaultdict(list), defaultdict(list)
    for section, state in actors_before.items():
        groups_before[signature(state, before['game'])].append((section, state))
    for section, state in actors_after.items():
        groups_after[signature(state, after['game'])].append((section, state))
    assert groups_before.keys() == groups_after.keys(), 'stable actor identity/location groups differ'
    pairs = []
    mapping, reverse, identities = {}, {}, {}
    map_counts = Counter()
    seen_categories = defaultdict(set)
    pair_reasons = Counter()
    def add_uid(old, new, category):
        assert isinstance(old, Atom) and isinstance(new, Atom) and old.kind == new.kind == 'n', 'invalid UID field'
        assert new not in mapping or mapping[new] == old, 'actual UID pairing conflict'
        assert old not in reverse or reverse[old] == new, 'expected UID pairing conflict'
        if new not in mapping:
            mapping[new] = old
            reverse[old] = new
        if old not in seen_categories[category]:
            seen_categories[category].add(old)
            map_counts[category + '_unique'] += 1
            if old != new:
                map_counts[category + '_changed'] += 1
    item_occurrences = 0
    def bind_pair(left, right, reason):
        nonlocal item_occurrences
        old_section, old = left
        new_section, new = right
        pairs.append((left, right))
        pair_reasons[reason] += 1
        add_uid(old[key('uid')], new[key('uid')], 'actor')
        old_inven, new_inven = old[key('inventory')], new[key('inventory')]
        assert old_inven.keys() == new_inven.keys(), 'inventory slot set differs'
        for slot in old_inven:
            assert old_inven[slot].keys() == new_inven[slot].keys(), 'inventory item indices differ'
            for index, old_item in old_inven[slot].items():
                new_item = new_inven[slot][index]
                item_occurrences += 1
                assert (key('uid') in old_item) == (key('uid') in new_item), 'inventory UID field presence differs'
                if key('uid') in old_item:
                    add_uid(old_item[key('uid')], new_item[key('uid')], 'inventory')
    remaining = []
    for group, left in groups_before.items():
        right = groups_after[group]
        assert len(left) == len(right), 'stable actor group cardinality differs'
        if len(left) == 1:
            bind_pair(left[0], right[0], 'stable_player_class_location')
        else:
            remaining.append((left.copy(), right.copy()))
    for left, right in remaining:
        while left:
            progress = False
            for old in left.copy():
                uid = old[1][key('uid')]
                if uid not in reverse:
                    continue
                candidates = [new for new in right if new[1][key('uid')] == reverse[uid]]
                assert len(candidates) == 1, 'inventory identity conflicts with actor group'
                new = candidates[0]
                bind_pair(old, new, 'inventory_slot_index_uid_link')
                left.remove(old); right.remove(new)
                progress = True
            if len(left) == len(right) == 1:
                bind_pair(left.pop(), right.pop(), 'single_remaining_in_stable_group')
                progress = True
            assert progress or not left, 'actor group still ambiguous after inventory UID links'
    pairs.sort(key=lambda pair: int(pair[0][0].split(':')[1]))
    for ordinal, ((old_section, old), (new_section, new)) in enumerate(pairs, 1):
        identities[old_section] = 'actor[player]' if old[key('uid')] == before['game'][key('player_uid')] else f'actor[{ordinal:02d}]'
    reference_anchors = []
    def reference_pairs(old, new, path):
        if isinstance(old, Atom) or isinstance(new, Atom):
            return
        # data() represents an opaque entity reference as precisely {uid,class}.
        # The containing actor, inventory position and field role are already
        # matched. Align these IDs only when their class also agrees; the global
        # bidirectional map must preserve aliases and distinct entity references.
        reference_keys = {key('uid'), key('class')}
        if old.keys() == new.keys() == reference_keys and old[key('class')] == new[key('class')]:
            uid_old, uid_new = old[key('uid')], new[key('uid')]
            if uid_new not in mapping:
                reference_anchors.append(path)
            add_uid(uid_old, uid_new, 'projected_reference')
        for k in old.keys() & new.keys():
            reference_pairs(old[k], new[k], path + component(k))
    reference_pairs(before['game'], after['game'], 'game')
    for (old_section, old), (new_section, new) in pairs:
        reference_pairs(old, new, identities[old_section])
    for old_uid, definition in before['party'][key('members')].items():
        assert old_uid in reverse, 'expected party member missing from UID map'
        new_uid = reverse[old_uid]
        assert new_uid in after['party'][key('members')], 'mapped party member absent'
        reference_pairs(definition, after['party'][key('members')][new_uid], 'party.members[matched_entity]')
    normalization_counts = Counter()
    unmapped = []
    def normalized(value, path):
        if isinstance(value, Atom):
            return value
        out = {}
        for k, child in value.items():
            child_path = path + component(k)
            if k in (key('uid'), key('player_uid')) and isinstance(child, Atom) and child.kind == 'n':
                if child in mapping:
                    normalization_counts['uid_fields_seen'] += 1
                    if mapping[child] != child:
                        normalization_counts['uid_fields_changed'] += 1
                    out[k] = mapping[child]
                else:
                    unmapped.append(child_path)
                    out[k] = child
            else:
                out[k] = normalized(child, child_path)
        return out
    normalized_after = {'game': normalized(after['game'], 'game')}
    party = normalized(after['party'], 'party')
    members = {}
    for uid, definition in party[key('members')].items():
        assert uid in mapping, 'party member UID not mapped'
        members[mapping[uid]] = definition
        normalization_counts['party_member_keys_seen'] += 1
        normalization_counts['party_member_keys_changed'] += mapping[uid] != uid
    party[key('members')] = members
    for position, uid in party[key('order')].items():
        assert uid in mapping, 'party order UID not mapped'
        party[key('order')][position] = mapping[uid]
        normalization_counts['party_order_uids_seen'] += 1
        normalization_counts['party_order_uids_changed'] += mapping[uid] != uid
    normalized_after['party'] = party
    for (old_section, old), (new_section, new) in pairs:
        normalized_after[old_section] = normalized(new, identities[old_section])
    result = []
    for section, expected in before.items():
        differences(expected, normalized_after[section], identities.get(section, section), result)
    output = {
        'parsed_expected_sections': len(before), 'parsed_actual_sections': len(after),
        'raw_sections_removed': len(raw_before.keys() - raw_after.keys()),
        'raw_sections_added': len(raw_after.keys() - raw_before.keys()),
        'raw_sections_changed_at_same_key': sum(raw_before[k] != raw_after[k] for k in raw_before.keys() & raw_after.keys()),
        'actor_pairs': len(pairs), 'ambiguous_actor_pairs': 0, 'inventory_occurrences_paired': item_occurrences,
        'actor_pair_methods': dict(pair_reasons), 'unique_uid_pairs': len(mapping),
        'projected_reference_anchor_paths': sorted(reference_anchors),
        'selected_entity_classes_expected': dict(Counter(state[key('__CLASSNAME')].value for state in actors_before.values())),
        'selected_entity_classes_actual': dict(Counter(state[key('__CLASSNAME')].value for state in actors_after.values())),
        'uid_mapping': dict(map_counts), 'normalization': dict(normalization_counts),
        'unmapped_uid_field_count': len(unmapped), 'unmapped_uid_field_paths': sorted(unmapped),
        'remaining_difference_count': len(result), 'remaining_difference_kinds': dict(Counter(r['kind'] for r in result)),
        'remaining_differences': result,
        'selected_content_equal_after_uid_normalization': not result and not unmapped,
        'canonical_byte_roundtrip_passed': True,
        'canonical_key_types_expected': key_types(before),
        'canonical_key_types_actual': key_types(after),
        'all_uid_relationships_bijective': True,
        'individual_pairing_uses_multiset_only': False,
    }
    return output


def self_test():
    checks = 0
    def check(condition):
        nonlocal checks
        assert condition, 'synthetic comparison self-test failed'
        checks += 1
    def n(value):
        return Atom('n', str(value))
    def table(**fields):
        return {key(k): v for k, v in fields.items()}
    def fixture(offset):
        ref = table(uid=n(3 + offset), **{'class': Atom('s', 'mod.class.Object')})
        item = table(uid=n(2 + offset), name=Atom('s', 'test;=你好'),
                     combat=table(self=ref, secondary=ref))
        entity = table(uid=n(1 + offset), __CLASSNAME=Atom('s', 'mod.class.Player'),
                       x=n(0), y=n(0), player=Atom('boolean', 'true'), life=n(13),
                       inventory={n(1): {n(1): item}})
        return {
            'game': table(player_uid=n(1 + offset), turn=n(12), paused=Atom('boolean', 'true')),
            'party': table(members={n(1 + offset): {}}, order={n(1): n(1 + offset)}),
            'actor:' + str(1 + offset): entity,
        }
    strange_keys = {Atom('boolean', 'true'): Atom('s', 'boolean key'), n(1): Atom('s', 'number key'),
                    key('UTF8'): Atom('s', '你好;=}')}
    check(Parser(encode(strange_keys).decode('utf-8')).parse() == strange_keys)
    with tempfile.TemporaryDirectory(prefix='tome-reload-parser-test-') as folder:
        old_path, new_path = Path(folder) / 'old.json', Path(folder) / 'new.json'
        def evaluate(old, new):
            old_path.write_text(json.dumps({k: encode(v).decode('utf-8') for k, v in old.items()}))
            new_path.write_text(json.dumps({k: encode(v).decode('utf-8') for k, v in new.items()}))
            return compare(old_path, new_path)
        old, new = fixture(0), fixture(10)
        report = evaluate(old, new)
        check(report['selected_content_equal_after_uid_normalization'] and report['unique_uid_pairs'] == 3)
        check(report['normalization']['uid_fields_changed'] == 5 and report['unmapped_uid_field_count'] == 0)
        changed = copy.deepcopy(new)
        changed['actor:11'][key('life')] = n(14)
        report = evaluate(old, changed)
        check(not report['selected_content_equal_after_uid_normalization']
              and report['remaining_differences'] == [{'kind': 'changed', 'path': 'actor[player].life'}])
        split = copy.deepcopy(new)
        split['actor:11'][key('inventory')][n(1)][n(1)][key('combat')][key('secondary')] = table(uid=n(14), **{'class': Atom('s', 'mod.class.Object')})
        try:
            evaluate(old, split)
        except AssertionError as error:
            check(str(error) == 'expected UID pairing conflict')
        else:
            check(False)
        old_unknown, new_unknown = copy.deepcopy(old), copy.deepcopy(new)
        old_unknown['actor:1'][key('unknown')] = table(uid=n(99))
        new_unknown['actor:11'][key('unknown')] = table(uid=n(99))
        report = evaluate(old_unknown, new_unknown)
        check(not report['selected_content_equal_after_uid_normalization'] and report['unmapped_uid_field_count'] == 1)
        old_ambiguous, new_ambiguous = copy.deepcopy(old), copy.deepcopy(new)
        for offset, capture in ((0, old_ambiguous), (10, new_ambiguous)):
            for uid in (4, 5):
                capture['actor:' + str(uid + offset)] = table(uid=n(uid + offset),
                    __CLASSNAME=Atom('s', 'mod.class.NPC'), inventory={})
        try:
            evaluate(old_ambiguous, new_ambiguous)
        except AssertionError as error:
            check(str(error) == 'actor group still ambiguous after inventory UID links')
        else:
            check(False)
    return checks


def discover(home, filename):
    matches = list(home.rglob(filename))
    assert len(matches) == 1, 'capture discovery ambiguous or missing'
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture_home', type=Path, nargs='?', help='session home containing both state JSON files')
    parser.add_argument('--reference-home', type=Path, help='source home whose faster-save-state.json must be identical')
    parser.add_argument('--label', help='public session label, not a save or character name')
    parser.add_argument('--output', type=Path, help='write metadata-only JSON')
    parser.add_argument('--require-complete', action='store_true', help='require completed=true/exit_code=0 in sibling process.json')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps({'synthetic_parser_and_uid_checks_passed': self_test()}))
        return 0
    if args.capture_home is None:
        parser.error('capture_home is required unless --self-test is used')
    try:
        expected = discover(args.capture_home, 'faster-save-state.json')
        actual = discover(args.capture_home, 'faster-reload-state.json')
        reference_equal = None
        if args.reference_home is not None:
            source = discover(args.reference_home, 'faster-save-state.json')
            reference_equal = source.read_bytes() == expected.read_bytes()
            assert reference_equal, 'copied expected capture differs from source capture'
        result = compare(expected, actual)
        result['comparison_passed'] = result['selected_content_equal_after_uid_normalization']
        process_path = args.capture_home.parent / 'process.json'
        process = json.loads(process_path.read_text()) if process_path.is_file() else {}
        result['session'] = args.label or args.capture_home.parent.name
        result['process'] = {k: process.get(k) for k in ('completed', 'exit_code')}
        complete = process.get('completed') is True and process.get('exit_code') == 0
        result['count_as_successful_reload_session'] = bool(args.require_complete and complete and result['comparison_passed'])
        result['expected_capture_matches_source_bytes'] = reference_equal
        if args.require_complete:
            assert complete, 'required completed session was not observed'
        result['scope'] = [
            'Entity.loaded assigns a fresh next_uid. Raw actor:N section names are not persistent identities; raw section inequality is expected after reload.',
            'The capture calls every selected entity actor when it has a talents table. Class counts distinguish Player, NPC and Object; inventory count is item occurrences, not distinct actors.',
            'Pair by player/class/location, then inventory actor+slot+index UID links, then a sole remaining member of an otherwise stable group. Never pair by equal UID alone.',
            'Only uid/player_uid fields, actor section identities, party member UID keys and party order UID values are normalized. Other numeric values and all other selected content are compared exactly.',
            'Opaque {uid,class} references outside those roots are anchored by the already-paired entity/inventory path and equal class. Bidirectional UID constraints preserve aliases and distinct references; their hidden entity contents are outside this projection.',
            'Truly indistinguishable selected entities can support only a multiset statement. This checker rejects unresolved identity groups rather than claiming individual matches; these captures require no multiset-only pairing.',
            'A successful capture comparison alone does not make a deliberately stopped probe a successful reload session. Only --require-complete plus completed=true/exit_code=0 allows that session flag.',
        ]
    except (AssertionError, ValueError, KeyError, IndexError) as error:
        # Our assertions contain fixed diagnostic labels, never saved values.
        result = {'comparison_passed': False, 'count_as_successful_reload_session': False,
                  'error_kind': type(error).__name__,
                  'error': str(error) if isinstance(error, AssertionError) else 'capture parse/schema validation failed'}
    payload = json.dumps(result, indent=2, ensure_ascii=True) + '\n'
    if args.output:
        args.output.write_text(payload)
    print(payload, end='')
    return 0 if result['comparison_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
