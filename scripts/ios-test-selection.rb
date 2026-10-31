#!/usr/bin/ruby
# frozen_string_literal: true

require 'json'
require 'open3'

module IOSTestSelection
  GROUPS = {
    'smoke' => {
      description: 'Create/edit, copy, completion, list switching, and gathered selection.',
      tests: %w[
        testCreatesAndEditsTextSnip
        testCopiesTextOnlySnip
        testTappingCompletionCircleTogglesWithoutEditingOrSelecting
        testListSwipeSwitchesListsFromAVisibleRow
        testSelectionPersistsAcrossLists
      ]
    },
    'editing' => {
      description: 'Inline drafts, Markdown, search editing, composer destinations, and persistence.',
      tests: %w[
        testCreatesAndEditsTextSnip
        testMarkdownSnipRendersExpandsAndPreservesSourceForEditingAndCopying
        testContextEditUsesInlineDraftAndPreservesAttachmentsOnCancel
        testSearchPreservesInlineSnipDraft
        testSearchEditReopensInItsOriginalListWithoutDiscardingDraft
        testQuickComposerLongPressSendsToAnotherListAndPreservesItsDraft
        testQuickComposerSendsWithoutOpeningTheEditor
        testInlineDraftRemainsEditableWhenItsListIsDeleted
      ]
    },
    'lists' => {
      description: 'Create, rename, appearance, rotation, delete, and move between lists.',
      tests: %w[
        testCompactListTabsCreateAndSwitchLists
        testNewListNameCollisionStillOpensEditorAndExplainsRenameConflict
        testExistingListKeepsEditsAfterChoosingAnIcon
        testListEditorKeepsDraftAcrossRotation
        testListEditorIconSearchKeepsControlsReachable
        testSelectorDeleteListKeepsItsSnips
        testCreatesListMovesSnipAndDeletesIt
      ]
    },
    'undo' => {
      description: 'Done and deletion Undo, Settings, contrast, search placement, and the deadline.',
      tests: %w[
        testDoneSnackbarUndoReopensTheSnip
        testDoneUndoRemainsActionableInSettings
        testDeleteToastUndoRestoresSnip
        testDeleteToastPresentationInDarkMode
        testDeleteToastStaysAboveSearchToolbar
        testSearchDoesNotExtendDeleteUndoWindow
        testCreatesListMovesSnipAndDeletesIt
      ]
    },
    'gathering' => {
      description: 'Gather, filter, copy/delete, merge, return, and persist moves.',
      tests: %w[
        testSelectionPersistsAcrossLists
        testSelectionSurvivesFilteringItsSourceRows
        testGatheredHeaderCopiesAndDeletesWithoutOpeningMore
        testMergesSelectedSnips
        testGatheredCardsKeepLayoutAndReturnTopItemWhileCollapsed
        testGatheredStackReturnsSnipsAndCancels
        testGatheredStackMenuMovesAndPersists
        testMultiListSelectionCreatesDestinationFromMoveMenu
        testSingleItemMoveCanAddFirstCustomList
      ]
    },
    'attachments' => {
      description: 'Attachment menus, preview, copy, editing, persistence, and seeded pickers.',
      tests: %w[
        testAttachmentAddMenuOffersFilesAndPhotos
        testAttachmentListImagePreviewAndSwipeDismiss
        testCopiesFileOnlySnipAttachments
        testLocalAttachmentsPreviewRemoveAndSurviveRelaunch
        testPhotoPickerStagesAChosenImage
        testEditorKeepsStagedPhotoWhenPhotoPickerIsCancelled
        testNativePickerAddReplacePreviewAndSaveWhenFixturesAreSeeded
      ]
    },
    'share' => {
      description: 'Share sheets and embedded extension; claims the loopback fixture.',
      tests: %w[
        testSharesMultipleSelectedSnips
        testSharesSnipBackIntoSnipSnap
        testSharePageShowsEveryListThenSaves
        testShareExtensionImportsExactlyOnceWhileMainAppIsOpen
        testShareExtensionImportsExactlyOnceWhileMainAppIsClosed
        testShareExtensionDefersExactlyOnceWhileMainStoreIsUnavailable
      ]
    }
  }.freeze

  def self.unit_test_sources
    root = File.expand_path('..', __dir__)
    project = File.join(root, 'SnipSnap.xcodeproj/project.pbxproj')
    contents, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', project)
    abort "Cannot read iOS unit target sources: #{error}" unless status.success?
    objects = JSON.parse(contents).fetch('objects')
    target = objects.values.find { |object| object['isa'] == 'PBXNativeTarget' && object['name'] == 'SnipSnapiOSTests' }
    parents = objects.flat_map do |id, object|
      object.fetch('children', []).map { |child| [child, id] }
    end.to_h
    resolve = lambda do |id|
      object = objects.fetch(id)
      directory = if object['sourceTree'] == 'SOURCE_ROOT' || !parents.key?(id)
                    root
                  else
                    resolve.call(parents.fetch(id))
                  end
      File.expand_path(object.fetch('path', ''), directory)
    end
    target.fetch('buildPhases').flat_map do |id|
      phase = objects.fetch(id)
      next [] unless phase['isa'] == 'PBXSourcesBuildPhase'
      phase.fetch('files').map { |file| resolve.call(objects.fetch(file).fetch('fileRef')) }
    end.select { |path| File.extname(path) == '.swift' }
  end

  def self.run(arguments)
    if arguments.length == 2 && arguments.first == '--unit-test'
      parents = unit_test_sources.flat_map do |path|
        File.read(path).scan(/^\s*(?:final\s+)?class (\w+)\s*:\s*(\w+)/)
      end.to_h
      classes = ['XCTestCase']
      loop do
        descendants = parents.select { |_, parent| classes.include?(parent) }.keys - classes
        break if descendants.empty?
        classes.concat(descendants)
      end
      name = arguments.last
      abort "Unknown iOS unit test class: #{name}" unless name == 'all' || parents.key?(name) && classes.include?(name)
      puts name
      return
    end
    inventory = File.read(File.expand_path('../SnipSnapiOSUITests/SnipSnapiOSUITests.swift', __dir__))
                    .scan(/^\s*func (test\w+)\s*\(/).flatten
    GROUPS.each do |name, group|
      missing = group.fetch(:tests) - inventory
      abort "UI group #{name} references missing methods: #{missing.join(', ')}" unless missing.empty?
      abort "UI group #{name} contains duplicate methods" unless group.fetch(:tests).uniq == group.fetch(:tests)
    end
    if arguments == ['--list-ui-groups']
      GROUPS.each do |name, group|
        puts "#{name} (#{group.fetch(:tests).length}): #{group.fetch(:description)}"
      end
      return
    end
    option, value = arguments
    abort 'Choose --ui-test METHOD|all or --ui-group GROUP.' unless arguments.length == 2
    case option
    when '--ui-test'
      abort "Unknown UI test method: #{value}" unless value == 'all' || inventory.include?(value)
      puts value
    when '--ui-group'
      group = GROUPS[value]
      abort "Unknown UI group: #{value}. Use --list-ui-groups." unless group
      puts group.fetch(:tests)
    else
      abort "Unknown selection option: #{option}"
    end
  end
end

IOSTestSelection.run(ARGV) if $PROGRAM_NAME == __FILE__
