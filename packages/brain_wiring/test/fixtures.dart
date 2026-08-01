/// Shared .ohcourse fixtures for the distiller/discourse tests.
library;

import 'dart:convert';

/// A minimal course that passes study_core's strict parser AND the
/// distill-time discourse invariant (1-2 discourse items per node).
Map<String, dynamic> validCourseJson() => {
      'schemaVersion': '1.0',
      'id': 'kalman-mini',
      'title': 'A Tiny Course',
      'nodes': [
        {
          'id': 'n1',
          'title': 'First Idea',
          'intake': 'The first idea, explained from the ground up.',
          'items': [
            {
              'id': 'n1-i1',
              'type': 'qa',
              'rung': 3,
              'prompt': 'What is the first idea?',
              'answer': 'The first idea.',
              'acceptable': ['first idea'],
            },
          ],
          'discourse': [
            {
              'kind': 'socratic',
              'prompt': 'What would break if the first idea were false?',
            },
            {
              'kind': 'explain_back',
              'prompt': 'Explain the first idea in your own words.',
            },
          ],
        },
        {
          'id': 'n2',
          'title': 'Second Idea',
          'prereqs': ['n1'],
          'intake': 'Builds on the first idea.',
          'items': [
            {
              'id': 'n2-i1',
              'type': 'cloze',
              'rung': 1,
              'text': 'The second idea is {{c1::built on the first}}.',
              'answers': {'c1': 'built on the first'},
            },
          ],
          'discourse': [
            {
              'kind': 'explain_back',
              'prompt': 'Teach the second idea back to a friend.',
            },
          ],
        },
      ],
    };

String validCourseText() => jsonEncode(validCourseJson());
