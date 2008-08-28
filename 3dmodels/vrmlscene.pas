{
  Copyright 2003-2008 Michalis Kamburelis.

  This file is part of "Kambi VRML game engine".

  "Kambi VRML game engine" is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  "Kambi VRML game engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with "Kambi VRML game engine"; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
}

{ @abstract(VRML scene as @link(TVRMLScene) class.) }

unit VRMLScene;

interface

uses
  SysUtils, Classes, VectorMath, Boxes3d,
  VRMLFields, VRMLNodes, KambiClassUtils, KambiUtils,
  VRMLShapeState, VRMLTriangleOctree, ProgressUnit, VRMLShapeStateOctree,
  Keys, KambiTimeUtils;

{$define read_interface}

type
  TDynArrayItem_1 = TTriangle3Single;
  PDynArrayItem_1 = PTriangle3Single;
  {$define DYNARRAY_1_IS_STRUCT}
  {$I dynarray_1.inc}
  TArray_Triangle3Single = TInfiniteArray_1;
  PArray_Triangle3Single = PInfiniteArray_1;
  TDynTriangle3SingleArray = TDynArray_1;

  { Internal helper type for TVRMLScene.
    @exclude }
  TVRMLSceneValidity = (fvBBox,
    fvVerticesCountNotOver, fvVerticesCountOver,
    fvTrianglesCountNotOver, fvTrianglesCountOver,
    fvFog,
    fvTrianglesListNotOverTriangulate, fvTrianglesListOverTriangulate,
    fvManifoldAndBorderEdges);

  { @exclude }
  TVRMLSceneValidities = set of TVRMLSceneValidity;

  TViewpointFunction = procedure (Node: TVRMLViewpointNode;
    const Transform: TMatrix4Single) of object;

  { Scene edge that is between exactly two triangles.
    It's used by @link(TVRMLScene.ManifoldEdges),
    and this is crucial for rendering silhouette shadow volumes in OpenGL. }
  TManifoldEdge = record
    { Index to get vertexes of this edge.
      The actual edge's vertexes are not recorded here (this would prevent
      using TVRMLScene.ShareManifoldAndBorderEdges with various scenes from
      the same animation). You should get them as the VertexIndex
      and (VertexIndex+1) mod 3 vertexes of the first triangle
      (i.e. Triangles[0]). }
    VertexIndex: Cardinal;

    { Indexes to TVRMLScene.Triangles(false) array }
    Triangles: array [0..1] of Cardinal;

    { These are vertexes at VertexIndex and (VertexIndex+1)mod 3 positions,
      but @italic(only at generation of manifold edges time).
      Like said in VertexIndex, keeping here actual vertex info would prevent
      TVRMLScene.ShareManifoldAndBorderEdges. However, using these when generating
      makes a great speed-up when generating manifold edges.

      Memory cost is acceptable: assume we have model with 10 000 faces,
      so 15 000 edges (assuming it's correctly closed manifold), so we waste
      15 000 * 2 * SizeOf(TVector3Single) = 360 000 bytes... that's really nothing
      to worry (we waste much more on other things).

      Checked with "The Castle": indeed, this costs about 1 MB memory
      (out of 218 MB...), with really lot of creatures... On the other hand,
      this causes small speed-up when loading: loading creatures is about
      5 seconds faster (18 with, 23 without this).

      So memory loss is small, speed gain is noticeable (but still small),
      implementation code is a little simplified, so I'm keeping this.
      Also, in the future, maybe it will be sensible
      to use this for actual shadow quad rendering, in cases when we know that
      TVRMLScene.ShareManifoldAndBorderEdges was not used to make it. }
    V0, V1: TVector3Single;
  end;
  PManifoldEdge = ^TManifoldEdge;

  TDynArrayItem_2 = TManifoldEdge;
  PDynArrayItem_2 = PManifoldEdge;
  {$define DYNARRAY_2_IS_STRUCT}
  {$I dynarray_2.inc}

  TDynManifoldEdgeArray = class(TDynArray_2)
  private
  end;

  { Scene edge that has one neighbor, i.e. border edge.
    It's used by @link(TVRMLScene.BorderEdges),
    and this is crucial for rendering silhouette shadow volumes in OpenGL. }
  TBorderEdge = record
    { Index to get vertex of this edge.
      The actual edge's vertexes are not recorded here (this would prevent
      using TVRMLScene.ShareManifoldAndBorderEdges with various scenes from
      the same animation). You should get them as the VertexIndex
      and (VertexIndex+1) mod 3 vertexes of the triangle TriangleIndex. }
    VertexIndex: Cardinal;

    { Index to TVRMLScene.Triangles(false) array. }
    TriangleIndex: Cardinal;
  end;
  PBorderEdge = ^TBorderEdge;

  TDynArrayItem_3 = TBorderEdge;
  PDynArrayItem_3 = PBorderEdge;
  {$define DYNARRAY_3_IS_STRUCT}
  {$I dynarray_3.inc}
  TDynBorderEdgeArray = TDynArray_3;

  { These are various features that may be freed by
    TVRMLScene.FreeResources.

    @italic(Warning): This is for experienced usage of TVRMLScene.
    Everything is explained in detail below, but still  --- if you have some
    doubts, or you just don't observe any memory shortage in your program,
    it's probably best to not use TVRMLScene.FreeResources.

    @unorderedList(
      @item(For frRootNode, you @italic(may) get nasty effects including crashes
        if you will use this in a wrong way.)

      @item(For frTextureDataInNodes, frBackgroundImageInNodes and TrianglesList,
        if you will free them unnecessarily
        (i.e. you will use it after you freed it), it will be automatically
        recreated on next use. So everything will work correctly, but you
        will experience unnecessary slowdown if we will need to recreate
        exactly the same resource over and over again.)

      @item(For frTextureDataInNodes, frBackgroundImageInNodes and frRootNode, note that
        freeing these resources too eagerly may make image cache
        (see ImagesCache) less effective. In normal circumstances,
        if you will use the same cache instance throughout the program,
        loaded images are reused. If you free frTextureDataInNodes or frRootNode
        too early, you may remove them from the cache too early, and lose
        a chance to reuse them. So you may cause unnecessary slowdown
        of preparing models, e.g. inside PrepareRender.)
    )
  }
  TVRMLSceneFreeResource = (
    { Free (and set to nil) RootNode of the scene. Works only if
      TVRMLScene.OwnsRootNode is @true (the general assertion is that
      TVRMLScene will @italic(never) free RootNode when OwnsRootNode is
      @false).

      frRootNode allows you to save some memory, but may be quite dangerous.
      You have to be careful then about what methods from the scene you use.
      Usually, you will prepare appropriate things first (usually by
      TVRMLSceneGL.PrepareRender), and after that call FreeResources
      with frRootNode.

      Note that event processing is impossible without RootNode nodes and
      fields and routes, so don't ever use this if you want to set
      TVRMLScene.ProcessEvents to @true.

      Note that if you will try to use a resource that was already freed
      by frRootNode, you may even get segfault (access violation).
      So be really careful, be sure to prepare everything first by
      TVRMLSceneGL.PrepareRender or such. }
    frRootNode,

    { Unloads the texture images/videos allocated in VRML texture nodes.

      It's useful if you know that you already prepared everything
      that needed the texture images, and you will not need texture images
      later. For TVRMLGLScene this means that you use Optimization
      method other than roNone,
      and you already did PrepareRender (so textures are already loaded to OpenGL),
      and your code will not access TextureImage / TextureVideo anymore.
      This is commonly @true for various games.

      Then you can call this to free some resources.

      Note that if you made an accident and you will use some TextureImage or
      TextureVideo after FreeResources, then you will get no crash,
      but texture image will be simply reloaded. So you may experience
      slowdown if you inappropriately use this feature.

      Oh, and note that if frRootNode and OwnsRootNode, then this is not
      necessary (as freeing RootNode also frees texture nodes, along with
      their texture). }
    frTextureDataInNodes,

    { Unloads the background images allocated in VRML Background nodes.
      The same comments as for frTextureDataInNodes apply. }
    frBackgroundImageInNodes,

    { Free triangle list created by TrianglesList(false) call.
      This list is also implicitly created by constructing triangle octree
      or ManifoldEdges or BorderEdges.

      Note that if you made an accident and you will use TrianglesList(false)
      after FreeResources, then you will get no crash,
      but TrianglesList(false) will be regenerated. So you may experience
      slowdown if you inappropriately use this feature. }
    frTrianglesListNotOverTriangulate,

    { Free triangle list created by TrianglesList(true) call.
      Analogous to frTrianglesListNotOverTriangulate.

      Note that if you made an accident and you will use TrianglesList(true)
      after FreeResources, then you will get no crash,
      but TrianglesList(true) will be regenerated. So you may experience
      slowdown if you inappropriately use this feature. }
    frTrianglesListOverTriangulate,

    { Free edges lists in ManifoldEdges and BorderEdges.

      Frees memory, but next call to ManifoldEdges and BorderEdges will
      need to calculate them again (or you will need to call
      TVRMLScene.ShareManifoldAndBorderEdges again).
      Note that using this scene as shadow caster for shadow volumes algorithm
      requires ManifoldEdges and BorderEdges. }
    frManifoldAndBorderEdges);

  TVRMLSceneFreeResources = set of TVRMLSceneFreeResource;

  TVRMLScene = class;

  TVRMLSceneNotification = procedure (Scene: TVRMLScene) of object;

  { VRML scene, a final class to handle VRML models
    (with the exception of rendering, which is delegated to descendants,
    like TVRMLGLScene for OpenGL).

    VRML scene works with a graph of VRML nodes
    rooted in RootNode. It also deconstructs this graph to a flat list
    of @link(TVRMLShapeState)
    objects. The basic idea is to "have" at the same time hierarchical
    view of the scene (in @link(RootNode)) and a flattened view of the same scene
    (in @link(ShapeStates) list).

    VRML scene also takes care of initiating and managing VRML events
    and routes mechanism (see ProcessEvents).

    Note that when you use this class and you directly
    change the scene within RootNode, you'll have to use our
    @code(Changed*) methods to notify this class about changes.
    Although whole @link(TVRMLNode) class works very nicely and you
    can freely change any part of it, add, delete and move nodes around
    and change their properties, this class has to be manually (for now)
    notified about such changes. Basically you can just call @link(ChangedAll)
    after changing anything inside @link(RootNode), but you should
    also take a look at other @code(Changed*) methods defined here.

    If the scene is changed by VRML events, all changes are automagically
    acted upon, so you don't have to do anything. In other words,
    this class takes care to automatically internally call appropriate @code(Changed*)
    methods when events change field values and such.

    This class provides many functionality.
    For more-or-less static scenes, many things are cached and work very
    quickly.
    E.g. methods LocalBoundingBox, BoundingBox, VerticesCount, TrianglesCount
    cache their results so after the first call to @link(TrianglesCount)
    next calls to the same method will return instantly (assuming
    that scene did not changed much). And the @link(ShapeStates) list
    is the main trick for various processing of the scene, most importantly
    it's the main trick to write a flexible OpenGL renderer of the VRML scene.

    Also, VRML2ActiveLights are magically updated for all states in
    ShapeStates list. This is crucial for lights rendering in VRML >= 2.0. }
  TVRMLScene = class
  private
    FOwnsRootNode: boolean;
    FShapeStates: TVRMLShapeStatesList;
    FRootNode: TVRMLNode;

    ChangedAll_TraversedLights: TDynActiveLightArray;
    procedure ChangedAll_Traverse(Node: TVRMLNode; State: TVRMLGraphTraverseState;
      ParentInfo: PTraversingInfo);

    FFogNode: TNodeFog;
    FFogDistanceScaling: Single;
    { calculate FFogNode and FFogDistanceScaling, include fvFog
      in Validities }
    procedure ValidateFog;

    FBoundingBox: TBox3d;
    FVerticesCountNotOver, FVerticesCountOver,
    FTrianglesCountNotOver, FTrianglesCountOver: Cardinal;
    Validities: TVRMLSceneValidities;
    function CalculateBoundingBox: TBox3d;
    function CalculateVerticesCount(OverTriangulate: boolean): Cardinal;
    function CalculateTrianglesCount(OverTriangulate: boolean): Cardinal;

    TriangleOctreeToAdd: TVRMLTriangleOctree;
    procedure AddTriangleToOctreeProgress(const Triangle: TTriangle3Single;
      State: TVRMLGraphTraverseState; GeometryNode: TVRMLGeometryNode;
      const MatNum, FaceCoordIndexBegin, FaceCoordIndexEnd: integer);

    FDefaultShapeStateOctree: TVRMLShapeStateOctree;
    FDefaultTriangleOctree: TVRMLTriangleOctree;
    FOwnsDefaultTriangleOctree: boolean;
    FOwnsDefaultShapeStateOctree: boolean;

    { If appropriate fvXxx is not in Validities, then
      - free if needed appropriate FTrianglesList[] item
      - calculate appropriate FTrianglesList[] item
      - add appropriate fvXxx to Validities. }
    procedure ValidateTrianglesList(OverTriangulate: boolean);
    FTrianglesList:
      array[boolean { OverTriangulate ?}] of TDynTriangle3SingleArray;

    function GetViewpointCore(
      const OnlyPerspective: boolean;
      out CamKind: TVRMLCameraKind;
      out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
      const ViewpointDescription: string):
      TVRMLViewpointNode;

    FManifoldEdges: TDynManifoldEdgeArray;
    FBorderEdges: TDynBorderEdgeArray;
    FOwnsManifoldAndBorderEdges: boolean;

    procedure CalculateIfNeededManifoldAndBorderEdges;

    procedure FreeResources_UnloadTextureData(Node: TVRMLNode);
    procedure FreeResources_UnloadBackgroundImage(Node: TVRMLNode);

    FOnBeforeChangedAll, FOnAfterChangedAll: TVRMLSceneNotification;
    FOnPostRedisplay: TVRMLSceneNotification;

    FProcessEvents: boolean;
    procedure SetProcessEvents(const Value: boolean);

    { This is collected by CollectNodesForEvents. @nil if not ProcessEvents. }
    KeySensorNodes, TimeSensorNodes, MovieTextureNodes: TVRMLNodesList;

    procedure CollectNodesForEvents;
    procedure Collect_KeySensor(Node: TVRMLNode);
    procedure Collect_TimeSensor(Node: TVRMLNode);
    procedure Collect_MovieTexture(Node: TVRMLNode);
    procedure Collect_ChangedFields(Node: TVRMLNode);

    procedure EventChanged(Event: TVRMLEvent; Value: TVRMLField;
      const Time: TKamTime);

    FWorldTime: TKamTime;

    { Internal procedure that handles WorldTime changes. }
    procedure InternalSetWorldTime(
      const NewValue, TimeIncrease: TKamTime);

    procedure ResetRoutesLastEventTime(Node: TVRMLNode);
  protected
    { Call OnPostRedisplay, if assigned. }
    procedure DoPostRedisplay;
  public
    constructor Create(ARootNode: TVRMLNode; AOwnsRootNode: boolean);
    destructor Destroy; override;

    { List of shape+states within this VRML scene.

      ShapeStates contents are read-only from outside.

      Note that the only place where ShapeStates length is changed
      in this class is ChangedAll procedure.
      So e.g. if you want to do something after each change of
      ShapeStates length, you can simply override ChangedAll
      and do your work after calling "inherited". }
    property ShapeStates: TVRMLShapeStatesList read FShapeStates;

    { Calculate bounding box, number of triangls and vertexes of all
      shapa states. For detailed specification of what these functions
      do (and what does OverTriangulate mean) see appropriate
      VRMLNodes.TNodeGenaralShape methods. Here, we just sum results
      of TNodeGenaralShape methods for all shapes.
      @groupBegin }
    function BoundingBox: TBox3d;
    function VerticesCount(OverTriangulate: boolean): Cardinal;
    function TrianglesCount(OverTriangulate: boolean): Cardinal;
    { @groupEnd }

    { Methods to notify this class about changes to the underlying RootNode
      graph. Since this class caches some things, it has to be notified
      when you manually change something within RootNode graph.

      Call ChangedAll to notify that "potentially everything changed",
      including adding/removal of some nodes within RootNode and changing their
      fields' values.
      This causes recalculation of all things dependent on RootNode.
      It's more optimal to use one of the other Changed* methods, when possible.

      Call ChangedShapeStateFields(ShapeStateNum) if you only changed
      values of fields within ShapeList[ShapeStateNum].GeometryNode,
      ShapeList[ShapeStateNum].State.Last* and
      ShapeList[ShapeStateNum].State.Active*. (And you're sure that
      these nodes are not shared by other shape+states using VRML DEF/USE
      mechanism.)

      Call ChangedFields when you only changed field values of given Node.
      This does relatively intelligent discovery of what could be possibly
      affected by changing this node, and updates/invalidates
      cache only where needed. It's acceptable to pass here a Node that
      isn't in the active VRML graph part (that is not reached by Traverse
      method), or even that isn't in the RootNode
      graph at all. Node can also be one of StateDefaultNodes that you took
      from one of State.LastNodes[]. So we really handle all cases here,
      and passing any node is fine here, and we'll try to intelligently
      detect what this change implicates for this VRML scene.

      @italic(Descendant implementors notes:) ChangedAll and
      ChangedShapeStateFields are virtual, so of course you can override them
      (remember to always call @code(inherited)). ChangedAll is also
      called by constructor of this class, so you can put a lot of your
      initialization there (instead of in the constructor).

      @groupBegin }
    procedure ChangedAll; virtual;
    procedure ChangedShapeStateFields(ShapeStateNum: Integer); virtual;
    procedure ChangedFields(Node: TVRMLNode);
    { @groupEnd }

    { Notification when ChangedAll is called. This is sometimes
      useful, since ChangedAll may be called from various places
      (like from internal events mechanism, if ProcessEvents is @true).
      And sometimes you have to react to ChangedAll, since it
      traverses the VRML graph again,
      recalculating State values... so the old States are not
      correct anymore. Unfortunately, this means that some things
      become invalid and have to recalculated, like triangle octree.

      @groupBegin }
    property OnBeforeChangedAll: TVRMLSceneNotification
      read FOnBeforeChangedAll write FOnBeforeChangedAll;
    property OnAfterChangedAll: TVRMLSceneNotification
      read FOnAfterChangedAll write FOnAfterChangedAll;
    { @groupEnd }

    { Notification when anything changed needing redisplay. }
    property OnPostRedisplay: TVRMLSceneNotification
      read FOnPostRedisplay write FOnPostRedisplay;

    { Returns short information about the scene.
      This consists of a few lines, separated by KambiUtils.NL.
      Last line also ends with KambiUtils.NL.

      Note that AManifoldAndBorderEdges = @true will require calculation
      of ManifoldEdges and BorderEdges (if they weren't calculated already).
      If you don't want to actually use them (if you wanted only to
      report them to user), then you may free them (freeing some memory)
      with @code(FreeResources([frManifoldAndBorderEdges])). }
    function Info(
      ATriangleVerticesCounts,
      ABoundingBox,
      AManifoldAndBorderEdges: boolean): string;

    function InfoTriangleVerticesCounts: string;
    function InfoBoundingBox: string;
    function InfoManifoldAndBorderEdges: string;

    { Write contents of all VRML "Info" nodes.
      Also write how many Info nodes there are in the scene. }
    procedure WritelnInfoNodes;

    { Actual VRML graph defining this VRML scene.
      This class can be viewed as a wrapper around specified RootNode.

      As such it is allowed to change contents of RootNode
      (however, this object requires notification of such changes
      via ChangedXxx methods, see their docs).
      Moreover it is allowed to change value of RootNode
      and even to set RootNode to nil for some time.

      This is useful for programs like view3dscene, that want to
      have one TVRMLScene for all the lifetime and only
      replace RootNode value from time to time.
      This is useful because it allows to change viewed model
      (by changing RootNode) while preserving values of things
      like Attributes properties in subclass @link(TVRMLGLScene).

      That's why it is possible to change RootNode and it is even
      possible to set it to nil. And when When RootNode = nil everything
      should work -- you can query such scene (with RootNode = nil)
      for Vecrtices/TrianglesCount (answer will be 0),
      for BoundingBox (answer will be EmptyBox3d),
      you can render such scene (nothing will be rendered) etc.
      Scene RootNode = nil will act quite like a Scene with
      e.g. no TVRMLGeometryNode nodes.

      Always call ChangedAll when you changed RootNode.

      Note that there is also a trick to conserve memory use.
      After you've done PrepareRender some things are precalculated here,
      and RootNode is actually not used. So you can free RootNode
      (and set it to nil here) @italic(without calling ChangedAll)
      and some things will just continue to work, unaware of the fact
      that the underlying RootNode structure is lost.
      Note that this is still considered a "trick", and you will
      have to be extra-careful then about what methods/properties
      from this class. Generally, use only things that you prepared
      with PrepareRender. So e.g. calling Render or using BoundingBox.
      If all your needs are that simple, then you can use this trick
      to save some memory. This is actually useful when using TVRMLGLAnimation,
      as it creates a lot of intermediate node structures and TVRMLScene
      instances. }
    property RootNode: TVRMLNode read FRootNode write FRootNode;

    { If @true, RootNode will be freed by destructor of this class. }
    property OwnsRootNode: boolean read FOwnsRootNode write FOwnsRootNode;

    { Create octree containing all triangles from our scene.
      Creates triangle-based octree, inits it with our BoundingBox
      and adds all triangles from our ShapeStates.
      Triangles are generated using calls like
      @code(GeometryNode.Triangulate(State, false, ...)).
      Note that OverTriangulate parameter for Triangulate call above is @false:
      it shouldn't be needed to have octree with over-triangulate
      (over-triangulate is for rendering with Gouraud shading).

      If ProgressTitle <> '' (and progress is not active already,
      so we avoid starting "progress bar within progress bar")
      then it uses @link(Progress) while building octree.

      Remember that such octree has a reference to Shape nodes
      inside RootNode vrml tree and to State objects inside
      our ShapeStates list.
      So you must not use this octree after freeing this object.
      Also you must rebuild such octree when this object changes.

      Note: remember that this is a function and it returns
      created octree object. It does *not* set value of property
      @link(DefaultTriangleOctree). But of course you can use it
      (and you often will) in code like

      @longCode(#  Scene.DefaultTriangleOctree := Scene.CreateTriangleOctree(...) #)

      @groupBegin }
    function CreateTriangleOctree(const ProgressTitle: string):
      TVRMLTriangleOctree; overload;
    function CreateTriangleOctree(AMaxDepth, AMaxLeafItemsCount: integer;
      const ProgressTitle: string): TVRMLTriangleOctree; overload;
    { @groupEnd }

    { Create octree containing all shape+states from our scene.
      Creates shape+state octree and inits it with our BoundingBox
      and adds all our ShapeStates.

      If ProgressTitle <> '' (and progress is not active already,
      so we avoid starting "progress bar within progress bar")
      then it uses @link(Progress) while building octree.

      Remember that such octree has a reference to our ShapeStates list.
      So you must not use this octree after freeing this object.
      Also you must rebuild such octree when this object changes.

      Note: remember that this is a function and it returns
      created octree object. It does *not* set value of property
      @link(DefaultShapeStateOctree). But of course you can use it
      (and you often will) in code like

      @longCode(#  Scene.DefaultShapeStateOctree := Scene.CreateShapeStateOctree(...) #)

      @groupBegin }
    function CreateShapeStateOctree(const ProgressTitle: string):
      TVRMLShapeStateOctree; overload;
    function CreateShapeStateOctree(AMaxDepth, AMaxLeafItemsCount: integer;
      const ProgressTitle: string): TVRMLShapeStateOctree; overload;
    { @groupEnd }

    { Notes for both DefaultTriangleOctree and
      DefaultShapeStateOctree:

      Everything in my units is done in the spirit
      that you can create as many octrees as you want for a given scene
      (both octrees based on triangles and based on shapestates).
      Also, in some special cases an octree may be constructed in
      some special way (not only using @link(CreateShapeStateOctree)
      or @link(CreateTriangleOctree)) so that it doesn't contain
      the whole scene from some TVRMLScene object, or it contains
      the scene from many TVRMLScene objects, or something else.

      What I want to say is that it's generally wrong to think of
      an octree as something that maps 1-1 to some TVRMLScene object.
      Octrees, as implemented here, are a lot more flexible.

      That said, it's very often the case that you actually want to
      create exactly one octree of each kind (one TVRMLTriangleOctree
      and one TVRMLShapeStateOctree) for each scene.
      Properties below make it easier for you.
      Basically you can use them however you like.
      They can simply serve for you as some variables inside
      TVRMLGLScene that you can use however you like,
      so that you don't have to declare two additional variables
      like SceneTriangleOctree and SceneShapeStateOctree
      each time you define variable Scene: TVRMLScene.

      Also, some methods in this class that take an octree from you
      as a parameter may have some overloaded versions that
      implicitly use octree objects stored in properties below,
      e.g. see @link(TVRMLGLScene.RenderFrustumOctree).

      This class modifies these properties in *only* one case:
      if OwnsDefaultTriangleOctree is true (default value)
      then at destruction this class calls FreeAndNil(DefaultTriangleOctree).
      Similar for DefaultShapeStateOctree.

      In any case, these properties are not managed by this object.
      E.g. these octrees are not automaticaly rebuild when you
      call ChangedAll.

      @groupBegin }
    property DefaultTriangleOctree: TVRMLTriangleOctree
      read FDefaultTriangleOctree write FDefaultTriangleOctree;

    property DefaultShapeStateOctree: TVRMLShapeStateOctree
      read FDefaultShapeStateOctree write FDefaultShapeStateOctree;

    property OwnsDefaultTriangleOctree: boolean
      read FOwnsDefaultTriangleOctree write FOwnsDefaultTriangleOctree
      default true;

    property OwnsDefaultShapeStateOctree: boolean
      read FOwnsDefaultShapeStateOctree write FOwnsDefaultShapeStateOctree
      default true;
    { @groupEnd }

    { GetViewpoint and GetPerspectiveViewpoint return the properties
      of the defined Viewpoint in VRML file, or some default viewpoint
      properties if no viewpoint is found in RootNode graph. They seek for
      nodes Viewpoint (for VRML 97) or OrthoViewpoint (any X3DViewpointNode
      actually, for X3D), PerspectiveCamera and OrthographicCamera
      (for VRML 1.0) in the scene graph.

      GetPerspectiveViewpoint omits OrthographicCamera andy OrthoViewpoint.

      If ViewpointDescription = '', they return the first found viewpoint node.
      Otherwise, they look for Viewpoint or OrthoViewpoint (any X3DViewpointNode
      actually) with description field mathing given string.

      If some viewpoint will be found (in the active VRML graph
      under RootNode), then "out" parameters
      will be calculated to this viewpoint position, direction etc.
      If no such thing is found in the VRML graph, then returns
      default viewpoint properties from VRML spec (CamPos = (0, 0, 1),
      CamDir = (0, 0, -1), CamUp = GravityUp = (0, 1, 0), CamType = ctPerspective).

      If camera properties were found in some node,
      it returns this node. Otherwise it returns nil.
      This way you can optionally extract some additional info from
      used viewpoint node, or do something special if default values
      were used. Often you will just ignore result of this function
      --- after all, the most important feature of this function
      is that you don't @italic(have) to care about details of
      dealing with camera node.

      Returned CamDir and CamUp and GravityUp are always normalized ---
      reasons the same as for TVRMLViewpointNode.GetCameraVectors.

      @groupBegin }
    function GetViewpoint(
      out CamKind: TVRMLCameraKind;
      out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
      const ViewpointDescription: string = ''):
      TVRMLViewpointNode;

    function GetPerspectiveViewpoint(
      out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
      const ViewpointDescription: string = ''):
      TVRMLViewpointNode;
    { @groupEnd }

    { This enumerates all viewpoint nodes (any X3DViewpointNode
      for VRML >= 2.0, PerspectiveCamera and OrthographicCamera for VRML 1.0)
      in the scene graph.
      For each such node, it calls ViewpointFunction.

      Essentially, this is a trivial wrapper over RootNode.Traverse
      that returns only TVRMLViewpointNode. }
    procedure EnumerateViewpoints(ViewpointFunction: TViewpointFunction);

    { Return fog defined by this VRML scene.

      FogNode returns current Fog node defined by this VRML model,
      or @nil if not found.

      FogDistanceScaling returns scaling of this FogNode, taken
      from the transformation of FogNode in VRML graph.
      You should always multiply FogNode.FdVisibilityRange.Value
      by FogDistanceScaling when applying (rendering etc.) this fog node.
      Value of FogDistanceScaling is undefined if FogNode = nil.

      Results of this functions are cached, so you can call them often,
      and they'll work fast, assuming the scene doesn't change.

      @groupBegin }
    function FogNode: TNodeFog;
    function FogDistanceScaling: Single;
    { @groupEnd }

    { This returns an array of all triangles of this scene.
      I.e. it triangulates the scene, adding all non-degenerated
      (see IsValidTriangles) triangles to the list.

      It's your responsibility what to do with resulting
      object, when to free it etc. }
    function CreateTrianglesList(OverTriangulate: boolean):
      TDynTriangle3SingleArray;

    { Just like CreateTrianglesList, but results of this function are cached,
      and returned object is read-only for you. Don't modify it, don't free it. }
    function TrianglesList(OverTriangulate: boolean):
      TDynTriangle3SingleArray;

    { ManifoldEdges is a list of edges that have exactly @bold(two) neighbor
      triangles, and BorderEdges is a list of edges that have exactly @bold(one)
      neighbor triangle. These are crucial for rendering shadows using shadow
      volumes.

      Edges with more than two neighbors are allowed. If an edge has an odd
      number of neighbors, it will be placed in BorderEdges. Every other pair
      of neighbors will be "paired" and placed as one manifold edge inside
      ManifoldEdges. So actually edge with exactly 1 neighbor (odd number,
      so makes one BorderEdges item) and edge with exactly 2 neighbors
      (even number, one pair of triangles, makes one item in ManifoldEdges)
      --- they are just a special case of a general rule, that allows any
      neighbors number.

      Note that vertexes must be consistently ordered in triangles.
      For two neighboring triangles, if one triangle's edge has
      order V0, V1, then on the neighbor triangle the order must be reversed
      (V1, V0). This is true in almost all situations, for example
      if you have a closed solid object and all outside faces are ordered
      consistently (all CCW or all CW).
      Failure to order consistently will result in edges not being "paired",
      i.e. we will not recognize that some 2 edges are in fact one edge between
      two neighboring triangles --- and this will result in more edges in
      BorderEdges.

      Both of these lists are calculated at once, i.e. when you call ManifoldEdges
      or BorderEdges for the 1st time, actually both ManifoldEdges and
      BorderEdges are calculated at once. If all edges are in ManifoldEdges,
      then the scene is a correct closed manifold, or rather it's composed
      from any number of closed manifolds.

      Results of these functions are cached, and are also owned by this object.
      So don't modify it, don't free it.

      This uses TrianglesList(false).

      @groupBegin }
    function ManifoldEdges: TDynManifoldEdgeArray;
    function BorderEdges: TDynBorderEdgeArray;
    { @groupEnd }

    { This allows you to "share" @link(ManifoldEdges) and
      @link(BorderEdges) values between TVRMLScene instances,
      to conserve memory and preparation time.
      The values set here will be returned by following ManifoldEdges and
      BorderEdges calls. The values passed here will @italic(not
      be owned) by this object --- you gave this, you're responsible for
      freeing it.

      This is handy if you know that this scene has the same
      ManifoldEdges and BorderEdges contents as some other scene. In particular,
      this is extremely handy in cases of animations in TVRMLGLAnimation,
      where all scenes actually need only a single instance of TDynManifoldEdgeArray
      and TDynBorderEdgeArray,
      this greatly speeds up TVRMLGLAnimation loading and reduces memory use.

      Note that passing here as values the same references
      that are already returned by ManifoldEdges / BorderEdges is always
      guaranteed to be a harmless operation. If ManifoldEdges  / BorderEdges
      was owned by this object,
      it will remain owned in this case (while in normal sharing situation,
      values set here are assumed to be owned by something else). }
    procedure ShareManifoldAndBorderEdges(
      ManifoldShared: TDynManifoldEdgeArray;
      BorderShared: TDynBorderEdgeArray);

    { Frees some scene resources, to conserve memory.
      See TVRMLSceneFreeResources documentation. }
    procedure FreeResources(Resources: TVRMLSceneFreeResources);

    { Should the VRML event mechanism work.

      If @true, then we will implement whole VRML event mechanism here,
      as expected from a VRML browser. Events will be send and received
      through routes, time dependent nodes (X3DTimeDependentNode,
      like TimeSensor) will be activated and updated from WorldTime time
      property (TODO), KeyDown, KeyUp and other methods will activate
      key/mouse sensor nodes, in the future scripts
      will also work (TODO), etc.

      Appropriate ChangedXxx, like ChangedAll, will be automatically called
      when necessary. TODO: some notification is needed when ChangedAll
      is called, or other ChangedXxx. E.g. view3dscene needs to know
      about such things.

      In other words, this makes the scene fully animated and interacting
      with the user (provided you will call KeyDown etc. methods when
      necessary).

      If @false, this all doesn't work, which makes the scene mostly
      static. TODO: how MovieTexture will work? Right now, it works,
      but it seems that it shouldn't without ProcessEvents. Unless
      we'll make an exception.
    }
    property ProcessEvents: boolean
      read FProcessEvents write SetProcessEvents default false;

    procedure KeyDown(Key: TKey; C: char; KeysDown: PKeysBooleans);
    procedure KeyUp(Key: TKey);

    { These change world time, see WorldTime.
      It is crucial that you call this continously to have some VRML
      time-dependent features working, like TimeSensor and MovieTexture.
      See WorldTime for details what is affected by this.

      This causes time to be passed to appropriate time-dependent nodes,
      events will be called etc.

      SetWorldTime and IncreaseWorldTime do exactly the same, the difference is
      only that for IncreaseWorldTime you specify increase in the time
      (that is, NewTime = WorldTime + TimeIncrease). Use whichever version
      is more handy.

      Following X3D specification, time should only grow. So NewValue should
      be > WorldTime (or TimeIncrease > 0).
      Otherwise we ignore this call.
      For resetting the time (when you don't necessarily want to grow WorldTime)
      see ResetWorldTime.

      If a change of WorldTime will produce some visible change in VRML model
      (for example, MovieTexture will change, or TimeSensor change will be
      routed by interpolator to coordinates of some visible node) this
      will be notified by usual method, that is OnPostRedisplay.

      @groupBegin }
    procedure SetWorldTime(const NewValue: TKamTime);
    procedure IncreaseWorldTime(const TimeIncrease: TKamTime);
    { @groupEnd }

    { This is the world time, that is passed to time-dependent nodes.
      See X3D specification "Time" component about time-dependent nodes.
      In short, this "drives" the time passed to TimeSensor, MovieTexture
      and AudioClip. See SetWorldTime for changing this.

      Default value is 0.0 (zero). }
    property WorldTime: TKamTime read FWorldTime write SetWorldTime;

    { Set WorldTime to arbitrary value.

      You should only use this when you loaded new VRML model.

      Unlike SetWorldTime and IncreaseWorldTime, this doesn't require that
      WorldTime grows. It still does some time-dependent events work,
      although some time-dependent nodes may be just unconditionally reset
      by this to starting value (as they keep local time, and so require
      TimeIncrease notion, without it we can only reset them).

      @groupBegin }
    procedure ResetWorldTime(const NewValue: TKamTime);
    { @groupEnd }
  end;

var
  { Starting state nodes for TVRMLScene
    and descendants when traversing VRML tree.

    It's needed that various TVRMLScene instances use the same
    StateDefaultNodes, because in some cases we assume that nodes
    are equal only when their references are equal
    (e.g. TVRMLGraphTraverseState.Equals does this, and this is used
    by ShapeState caching in TVRMLOpenGLRendererContextCache).

    This is read-only from outside, initialized and finalized in
    this unit. }
  StateDefaultNodes: TTraverseStateLastNodes;

{$undef read_interface}

implementation

uses VRMLCameraUtils;

{$define read_implementation}
{$I macprecalcvaluereturn.inc}
{$I dynarray_1.inc}
{$I dynarray_2.inc}
{$I dynarray_3.inc}

{ TODO - I tu dochodzimy do mechanizmu automatycznego wywolywania odpowiedniego
  Changed. Byloby to bardzo wygodne, prawda ? Obecnie wszystkie node'y
  maja juz liste swoich Parents; na pewno bedziemy musieli to zrobic
  takze dla wszystkich TVRMLField. I jeszcze trzeba zrobic mechanizm zeby
  node mogl przeslac informacje wyzej, do TVRMLShapeState lub
  TVRMLScene. Sporo tu do zrobienia - jak tylko mi sie to
  skrystalizuje zrobie to.

  This will be essentially done when events/routes mechanism will be done.
}

{ TVRMLScene ----------------------------------------------------------- }

constructor TVRMLScene.Create(ARootNode: TVRMLNode; AOwnsRootNode: boolean);
begin
 inherited Create;
 FRootNode := ARootNode;
 FOwnsRootNode := AOwnsRootNode;

 FOwnsDefaultTriangleOctree := true;
 FOwnsDefaultShapeStateOctree := true;

 FShapeStates := TVRMLShapeStatesList.Create;

 ChangedAll;
end;

destructor TVRMLScene.Destroy;
begin
  { This also frees related lists, like KeySensorNodes }
  ProcessEvents := false;

 FreeAndNil(FTrianglesList[false]);
 FreeAndNil(FTrianglesList[true]);

 if FOwnsManifoldAndBorderEdges then
 begin
   FreeAndNil(FManifoldEdges);
   FreeAndNil(FBorderEdges);
 end;

 ShapeStates.FreeWithContents;

 if OwnsDefaultTriangleOctree then FreeAndNil(FDefaultTriangleOctree);
 if OwnsDefaultShapeStateOctree then FreeAndNil(FDefaultShapeStateOctree);
 if OwnsRootNode then FreeAndNil(FRootNode);
 inherited;
end;

function TVRMLScene.CalculateBoundingBox: TBox3d;
var i: integer;
begin
 Result := EmptyBox3d;
 for i := 0 to ShapeStates.Count-1 do
  Box3dSumTo1st(Result, ShapeStates[i].BoundingBox);
end;

function TVRMLScene.CalculateVerticesCount(OverTriangulate: boolean): Cardinal;
var i: integer;
begin
 Result := 0;
 for i := 0 to ShapeStates.Count-1 do
  Result += ShapeStates[i].VerticesCount(OverTriangulate);
end;

function TVRMLScene.CalculateTrianglesCount(OverTriangulate: boolean): Cardinal;
var i: integer;
begin
 Result := 0;
 for i := 0 to ShapeStates.Count-1 do
  Result += ShapeStates[i].TrianglesCount(OverTriangulate);
end;

function TVRMLScene.BoundingBox: TBox3d;
{$define PRECALC_VALUE_ENUM := fvBBox}
{$define PRECALC_VALUE := FBoundingBox}
{$define PRECALC_VALUE_CALCULATE := CalculateBoundingBox}
PRECALC_VALUE_RETURN

function TVRMLScene.VerticesCount(OverTriangulate: boolean): Cardinal;
begin
 {$define PRECALC_VALUE_CALCULATE := CalculateVerticesCount(OverTriangulate)}
 if OverTriangulate then
 begin
  {$define PRECALC_VALUE_ENUM := fvVerticesCountOver}
  {$define PRECALC_VALUE := FVerticesCountOver}
  PRECALC_VALUE_RETURN
 end else
 begin
  {$define PRECALC_VALUE_ENUM := fvVerticesCountNotOver}
  {$define PRECALC_VALUE := FVerticesCountNotOver}
  PRECALC_VALUE_RETURN
 end;
end;

function TVRMLScene.TrianglesCount(OverTriangulate: boolean): Cardinal;
begin
 {$define PRECALC_VALUE_CALCULATE := CalculateTrianglesCount(OverTriangulate)}
 if OverTriangulate then
 begin
  {$define PRECALC_VALUE_ENUM := fvTrianglesCountOver}
  {$define PRECALC_VALUE := FTrianglesCountOver}
  PRECALC_VALUE_RETURN
 end else
 begin
  {$define PRECALC_VALUE_ENUM := fvTrianglesCountNotOver}
  {$define PRECALC_VALUE := FTrianglesCountNotOver}
  PRECALC_VALUE_RETURN
 end;
end;

procedure TVRMLScene.ChangedAll_Traverse(
  Node: TVRMLNode; State: TVRMLGraphTraverseState; ParentInfo: PTraversingInfo);
{ This does two things. These two things are independent, but both
  require Traverse to be done, and both have to be done in ChangedAll call...
  So it's efficient to do them at once.
  1. Add shapes to ShapeStates
  2. Add lights to ChangedAll_TraversedLights }
begin
  if Node is TVRMLGeometryNode then
  begin
    ShapeStates.Add(
      TVRMLShapeState.Create(Node as TVRMLGeometryNode,
      TVRMLGraphTraverseState.CreateCopy(State)));
  end else
  if Node is TVRMLLightNode then
  begin
    ChangedAll_TraversedLights.AppendItem(
      (Node as TVRMLLightNode).CreateActiveLight(State));
  end;
end;

procedure TVRMLScene.ChangedAll;

  procedure UpdateVRML2ActiveLights;

    procedure AddLightEverywhere(const L: TActiveLight);
    var
      J: Integer;
    begin
      for J := 0 to ShapeStates.Count - 1 do
        ShapeStates[J].State.VRML2ActiveLights.AppendItem(L);
    end;

    { Add L everywhere within given Radius from Location.
      Note that this will calculate BoundingBox of every ShapeState
      (but that's simply unavoidable if you have scene with VRML 2.0
      positional lights). }
    procedure AddLightRadius(const L: TActiveLight;
      const Location: TVector3Single; const Radius: Single);
    var
      J: Integer;
    begin
      for J := 0 to ShapeStates.Count - 1 do
        if Box3dSphereCollision(ShapeStates[J].BoundingBox,
             Location, Radius) then
          ShapeStates[J].State.VRML2ActiveLights.AppendItem(L);
    end;

  var
    I: Integer;
    L: PActiveLight;
    LNode: TVRMLLightNode;
  begin
    for I := 0 to ChangedAll_TraversedLights.High do
    begin
      { TODO: for spot lights, it would be an optimization to also limit
        ActiveLights by spot cone size. }
      L := ChangedAll_TraversedLights.Pointers[I];
      LNode := L^.LightNode;
      if (LNode is TNodePointLight_1) or
         (LNode is TNodeSpotLight_1) then
        AddLightEverywhere(L^) else
      if LNode is TNodePointLight_2 then
        AddLightRadius(L^, L^.TransfLocation, L^.TransfRadius) else
      if LNode is TNodeSpotLight_2 then
        AddLightRadius(L^, L^.TransfLocation, L^.TransfRadius);
      { Other light types (directional) should be handled by
        TVRMLGroupingNode.BeforeTraverse }
    end;
  end;

var
  InitialState: TVRMLGraphTraverseState;
begin
  { TODO: FManifoldEdges and FBorderEdges and triangles lists should be freed
    (and removed from Validities) on any ChangedXxx call. }

  if Assigned(OnBeforeChangedAll) then
    OnBeforeChangedAll(Self);

  ChangedAll_TraversedLights := TDynActiveLightArray.Create;
  try
    ShapeStates.FreeContents;
    Validities := [];

    if RootNode <> nil then
    begin
      InitialState := TVRMLGraphTraverseState.Create(StateDefaultNodes);
      try
        RootNode.Traverse(InitialState, TVRMLNode,
          {$ifdef FPC_OBJFPC} @ {$endif} ChangedAll_Traverse);
      finally InitialState.Free end;

      UpdateVRML2ActiveLights;

      if ProcessEvents then
        CollectNodesForEvents;
    end;
  finally FreeAndNil(ChangedAll_TraversedLights) end;

  if Assigned(OnAfterChangedAll) then
    OnAfterChangedAll(Self);

  DoPostRedisplay;
end;

procedure TVRMLScene.ChangedShapeStateFields(ShapeStateNum: integer);
begin
  Validities := [];
  ShapeStates[ShapeStateNum].Changed;
  DoPostRedisplay;
end;

procedure TVRMLScene.ChangedFields(Node: TVRMLNode);
var
  NodeLastNodesIndex, i: integer;
  Coord: TMFVec3f;
begin
  NodeLastNodesIndex := Node.TraverseStateLastNodesIndex;

  { Tests: Writeln('ChangedFields ', Node.ClassName, ' (', Node.NodeTypeName, ')'); }

  { Ignore this ChangedFields call if node is not in our VRML graph.
    Or is the inactive part. The definition of "active" part
    (see e.g. TVRMLNode.Traverse) is exactly such that we can ignore
    non-active parts here.

    Exception is for StateDefaultNodes nodes (they are not present in RootNode
    graph, but influence us).

    Zakladamy tutaj ze IsNodePresent(,true) zwraca stan Node'a zarowno
    przed modyfkacja pola jak i po - innymi slowy, zakladamy tu ze zmiana
    pola node'a nie mogla zmienic jego wlasnego stanu active/inactive. }

  if (RootNode = nil) or
     ( (not RootNode.IsNodePresent(Node, true)) and
       ((NodeLastNodesIndex = -1) or
         (StateDefaultNodes.Nodes[NodeLastNodesIndex] <> Node))
     ) then
    Exit;

  if Node is TNodeComposedShader then
  begin
    { Do nothing here, as TVRMLOpenGLRenderer registers and takes care
      to update shaders' uniform variables. We don't have to do
      anything here, no need to rebuild/recalculate anything.
      The only thing that needs to be called is redisplay, by DoPostRedisplay
      at the end of ChangedFields. }
  end else
  if Node is TNodeCoordinate then
  begin
    { TNodeCoordinate is special, although it's part of VRML 1.0 state,
      it can also occur within coordinate-based nodes of VRML >= 2.0.
      So it affects coordinate-based nodes with this node.

      In fact, code below takes into account both VRML 1.0 and 2.0 situation,
      that's why it's before "if NodeLastNodesIndex <> -1 then" branch. }
    for I := 0 to ShapeStates.Count - 1 do
      if ShapeStates[I].GeometryNode.Coord(ShapeStates[I].State, Coord) and
         (Coord.ParentNode = Node) then
        ChangedShapeStateFields(I);
  end else
  if NodeLastNodesIndex <> -1 then
  begin
    { Node is part of VRML 1.0 state, so it affects ShapeStates where
      it's present on State.LastNodes list. }
    for i := 0 to ShapeStates.Count - 1 do
      if ShapeStates[i].State.LastNodes.Nodes[NodeLastNodesIndex] = Node then
        ChangedShapeStateFields(i);
  end else
  if Node is TNodeMaterial_2 then
  begin
    { VRML 2.0 Material affects only shapes where it's
      placed inside Appearance.material field. }
    for I := 0 to ShapeStates.Count - 1 do
      if ShapeStates[I].State.ParentShape.Material = Node then
        ChangedShapeStateFields(I);
  end else
  if Node is TNodeX3DTextureCoordinateNode then
  begin
    { VRML 2.0 TextureCoordinate affects only shapes where it's
      placed inside texCoord field. }
    for I := 0 to ShapeStates.Count - 1 do
      if (ShapeStates[I].GeometryNode is TNodeX3DComposedGeometryNode) and
         (TNodeX3DComposedGeometryNode(ShapeStates[I].GeometryNode).
           FdTexCoord.Value = Node) then
        ChangedShapeStateFields(I);
  end else
  if Node is TVRMLLightNode then
  begin
    { node jest jednym z node'ow Active*. Wiec wplynal tylko na ShapeStates
      gdzie wystepuje jako Active.

      We use CurrentActiveLights, so possibly VRML2ActiveLights here ---
      that's OK, they are valid because UpdateVRML2ActiveLights was called
      when construcing ShapeStates list. }
    for i := 0 to ShapeStates.Count-1 do
      if ShapeStates[i].State.CurrentActiveLights.
           IndexOfLightNode(TVRMLLightNode(Node)) >= 0 then
        ChangedShapeStateFields(i);
  end else
  if Node is TVRMLGeometryNode then
  begin
    { node jest Shape'm. Wiec wplynal tylko na ShapeStates gdzie wystepuje jako
      GeometryNode. }
    for i := 0 to ShapeStates.Count-1 do
      if ShapeStates[i].GeometryNode = Node then
        ChangedShapeStateFields(i);
  end else
  begin
    { node jest czyms innym; wiec musimy zalozyc ze zmiana jego pol wplynela
      jakos na State nastepujacych po nim node'ow (a moze nawet wplynela na to
      co znajduje sie w aktywnej czesci grafu VRMLa pod niniejszym node'm -
      tak sie moglo stac gdy zmienilismy pole Switch.whichChild. ) }
    ChangedAll;
    Exit;
  end;

  DoPostRedisplay;
end;

procedure TVRMLScene.DoPostRedisplay;
begin
  if Assigned(OnPostRedisplay) then
    OnPostRedisplay(Self);
end;

resourcestring
  SSceneInfoTriVertCounts_Same = 'Scene contains %d triangles and %d ' +
    'vertices (with and without over-triangulating).';
  SSceneInfoTriVertCounts_1 =
    'When we don''t use over-triangulating (e.g. when we do collision '+
    'detection or ray tracing) scene has %d triangles and %d vertices.';
  SSceneInfoTriVertCounts_2 =
    'When we use over-triangulating (e.g. when we do OpenGL rendering) '+
    'scene has %d triangles and %d vertices.';

function TVRMLScene.InfoTriangleVerticesCounts: string;
begin
  if (VerticesCount(false) = VerticesCount(true)) and
     (TrianglesCount(false) = TrianglesCount(true)) then
    Result := Format(SSceneInfoTriVertCounts_Same,
      [TrianglesCount(false), VerticesCount(false)]) + NL else
  begin
    Result :=
      Format(SSceneInfoTriVertCounts_1,
        [TrianglesCount(false), VerticesCount(false)]) + NL +
      Format(SSceneInfoTriVertCounts_2,
        [TrianglesCount(true), VerticesCount(true)]) + NL;
  end;
end;

function TVRMLScene.InfoBoundingBox: string;
var
  BBox: TBox3d;
begin
  BBox := BoundingBox;
  Result := 'Bounding box : ' + Box3dToNiceStr(BBox);
  if not IsEmptyBox3d(BBox) then
  begin
    Result += ', average size : ' + FloatToNiceStr(Box3dAvgSize(BBox));
  end;
  Result += NL;
end;

function TVRMLScene.InfoManifoldAndBorderEdges: string;
begin
  Result := Format('Edges detection: all edges split into %d manifold edges and %d border edges. Note that for some algorithms, like shadow volumes, perfect manifold (that is, no border edges) works best.',
    [ ManifoldEdges.Count,
      BorderEdges.Count ]) + NL;
end;

function TVRMLScene.Info(
  ATriangleVerticesCounts,
  ABoundingBox,
  AManifoldAndBorderEdges: boolean): string;
begin
  Result := '';

  if ATriangleVerticesCounts then
  begin
    Result += InfoTriangleVerticesCounts;
  end;

  if ABoundingBox then
  begin
    if Result <> '' then Result += NL;
    Result += InfoBoundingBox;
  end;

  if AManifoldAndBorderEdges then
  begin
    if Result <> '' then Result += NL;
    Result += InfoManifoldAndBorderEdges;
  end;
end;

type
  TInfoNodeWriter = class
    Count: Cardinal;
    procedure WriteNode(node: TVRMLNode);
  end;
  procedure TInfoNodeWriter.WriteNode(node: TVRMLNode);
  begin
   Inc(Count);
   Writeln('Info node : "',(Node as TNodeInfo).FdString.Value, '"')
  end;

procedure TVRMLScene.WritelnInfoNodes;
var W: TInfoNodeWriter;
begin
 if RootNode = nil then Exit;

 W := TInfoNodeWriter.Create;
 try
  RootNode.EnumerateNodes(TNodeInfo,
    {$ifdef FPC_OBJFPC} @ {$endif} W.WriteNode, false);
  Writeln(W.Count, ' Info nodes in the scene.');
 finally W.Free end;
end;

{ using triangle octree -------------------------------------------------- }

procedure TVRMLScene.AddTriangleToOctreeProgress(
  const Triangle: TTriangle3Single;
  State: TVRMLGraphTraverseState; GeometryNode: TVRMLGeometryNode;
  const MatNum, FaceCoordIndexBegin, FaceCoordIndexEnd: integer);
begin
  Progress.Step;
  TriangleOctreeToAdd.AddItemTriangle(Triangle, State, GeometryNode, MatNum,
    FaceCoordIndexBegin, FaceCoordIndexEnd);
end;

function TVRMLScene.CreateTriangleOctree(const ProgressTitle: string):
  TVRMLTriangleOctree;
begin
 result := CreateTriangleOctree(
   DefTriangleOctreeMaxDepth,
   DefTriangleOctreeMaxLeafItemsCount,
   ProgressTitle);
end;

function TVRMLScene.CreateTriangleOctree(
  AMaxDepth, AMaxLeafItemsCount: integer;
  const ProgressTitle: string): TVRMLTriangleOctree;

  procedure FillOctree(AddTriProc: TNewTriangleProc);
  var i: integer;
  begin
   for i := 0 to ShapeStates.Count-1 do
    ShapeStates[i].GeometryNode.Triangulate(ShapeStates[i].State, false, AddTriProc);
  end;

begin
 result := TVRMLTriangleOctree.Create(AMaxDepth, AMaxLeafItemsCount, BoundingBox);
 try
  result.OctreeItems.AllowedCapacityOverflow := TrianglesCount(false);
  try
   if (ProgressTitle <> '') and (not Progress.Active) then
   begin
    Progress.Init(TrianglesCount(false), ProgressTitle, true);
    try
     TriangleOctreeToAdd := result;
     FillOctree({$ifdef FPC_OBJFPC} @ {$endif} AddTriangleToOctreeProgress);
    finally Progress.Fini end;
   end else
    FillOctree({$ifdef FPC_OBJFPC} @ {$endif} Result.AddItemTriangle);
  finally
   result.OctreeItems.AllowedCapacityOverflow := 4;
  end;
 except result.Free; raise end;
end;

{ using shapestate octree ---------------------------------------- }

function TVRMLScene.CreateShapeStateOctree(const ProgressTitle: string):
  TVRMLShapeStateOctree;
begin
 Result := CreateShapeStateOctree(
   DefShapeStateOctreeMaxDepth,
   DefShapeStateOctreeMaxLeafItemsCount,
   ProgressTitle);
end;

function TVRMLScene.CreateShapeStateOctree(
  AMaxDepth, AMaxLeafItemsCount: integer;
  const ProgressTitle: string): TVRMLShapeStateOctree;
var i: Integer;
begin
 Result := TVRMLShapeStateOctree.Create(AMaxDepth, AMaxLeafItemsCount,
   BoundingBox, ShapeStates);
 try

  if (ProgressTitle <> '') and (not Progress.Active) then
  begin
   Progress.Init(ShapeStates.Count, ProgressTitle, true);
   try
    for i := 0 to ShapeStates.Count - 1 do
    begin
     Result.TreeRoot.AddItem(i);
     Progress.Step;
    end;
   finally Progress.Fini end;
  end else
  begin
   for i := 0 to ShapeStates.Count - 1 do
    Result.TreeRoot.AddItem(i);
  end;

 except Result.Free; raise end;
end;

{ viewpoints ----------------------------------------------------------------- }

type
  TViewpointsSeeker = class
    ViewpointFunction: TViewpointFunction;
    procedure Seek(ANode: TVRMLNode; AState: TVRMLGraphTraverseState;
      ParentInfo: PTraversingInfo);
  end;

  procedure TViewpointsSeeker.Seek(
    ANode: TVRMLNode; AState: TVRMLGraphTraverseState;
    ParentInfo: PTraversingInfo);
  begin
    ViewpointFunction(
      TVRMLViewpointNode(ANode),
      AState.Transform);
  end;

procedure TVRMLScene.EnumerateViewpoints(
  ViewpointFunction: TViewpointFunction);
var
  InitialState: TVRMLGraphTraverseState;
  Seeker: TViewpointsSeeker;
begin
  if RootNode <> nil then
  begin
    InitialState := TVRMLGraphTraverseState.Create(StateDefaultNodes);
    try
      Seeker := TViewpointsSeeker.Create;
      try
        Seeker.ViewpointFunction := ViewpointFunction;
        RootNode.Traverse(InitialState, TVRMLViewpointNode,
          {$ifdef FPC_OBJFPC} @ {$endif} Seeker.Seek);
      finally FreeAndNil(Seeker) end;
    finally FreeAndNil(InitialState) end;
  end;
end;

type
  BreakFirstViewpointFound = class(TCodeBreaker);

  TFirstViewpointSeeker = class
    OnlyPerspective: boolean;
    ViewpointDescription: string;
    FoundNode: TVRMLViewpointNode;
    FoundTransform: PMatrix4Single;
    procedure Seek(Node: TVRMLViewpointNode;
      const Transform: TMatrix4Single);
  end;

  procedure TFirstViewpointSeeker.Seek(
    Node: TVRMLViewpointNode;
    const Transform: TMatrix4Single);
  begin
    if ( (not OnlyPerspective) or
         (Node.CameraKind = ckPerspective) ) and
       ( (ViewpointDescription = '') or
         ( (Node is TNodeX3DViewpointNode) and
           (TNodeX3DViewpointNode(Node).FdDescription.Value = ViewpointDescription) ) ) then
    begin
      FoundTransform^ := Transform;
      FoundNode := Node;
      raise BreakFirstViewpointFound.Create;
    end;
  end;

function TVRMLScene.GetViewpointCore(
  const OnlyPerspective: boolean;
  out CamKind: TVRMLCameraKind;
  out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
  const ViewpointDescription: string): TVRMLViewpointNode;
var
  CamTransform: TMatrix4Single;
  Seeker: TFirstViewpointSeeker;
begin
  Result := nil;
  Seeker := TFirstViewpointSeeker.Create;
  try
    Seeker.OnlyPerspective := OnlyPerspective;
    Seeker.ViewpointDescription := ViewpointDescription;
    Seeker.FoundTransform := @CamTransform;
    try
      EnumerateViewpoints({$ifdef FPC_OBJFPC} @ {$endif} Seeker.Seek);
    except
      on BreakFirstViewpointFound do
      begin
        Result := Seeker.FoundNode;
      end;
    end;
  finally FreeAndNil(Seeker) end;

  if Result <> nil then
  begin
    Result.GetCameraVectors(CamTransform, CamPos, CamDir, CamUp, GravityUp);
    CamKind := Result.CameraKind;
  end else
  begin
    { use default camera settings }
    CamPos := StdVRMLCamPos[1];
    CamDir := StdVRMLCamDir;
    CamUp := StdVRMLCamUp;
    GravityUp := StdVRMLGravityUp;
    CamKind := ckPerspective;
  end;
end;

function TVRMLScene.GetViewpoint(
  out CamKind: TVRMLCameraKind;
  out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
  const ViewpointDescription: string): TVRMLViewpointNode;
begin
  Result := GetViewpointCore(false, CamKind, CamPos, CamDir, CamUp, GravityUp,
    ViewpointDescription);
end;

function TVRMLScene.GetPerspectiveViewpoint(
  out CamPos, CamDir, CamUp, GravityUp: TVector3Single;
  const ViewpointDescription: string): TVRMLViewpointNode;
var
  CamKind: TVRMLCameraKind;
begin
  Result := GetViewpointCore(true, CamKind, CamPos, CamDir, CamUp, GravityUp,
    ViewpointDescription);
  Assert(CamKind = ckPerspective);
end;

{ fog ---------------------------------------------------------------------- }

procedure TVRMLScene.ValidateFog;
var
  FogTransform: TMatrix4Single;
  FogAverageScaleTransform: Single;
  InitialState: TVRMLGraphTraverseState;
begin
 InitialState := TVRMLGraphTraverseState.Create(StateDefaultNodes);
 try
  if (RootNode <> nil) and
    RootNode.TryFindNodeTransform(InitialState, TNodeFog, TVRMLNode(FFogNode),
      FogTransform, FogAverageScaleTransform) then
  begin
    { TODO: Using FogAverageScaleTransform is a simplification here.
      If we have non-uniform scaling, then FogAverageScaleTransform (and
      FogDistanceScaling) shouldn't  be used at all.

      Zamiast FFogDistanceScaling powinnismy
      sobie tutaj jakos wyliczac transformacje odwrotna do FogTransform.
      Potem kazdy element ktory bedziemy rysowac najpierw zrzutujemy
      do coordinate space node'u mgly, podobnie jak pozycje kamery,
      obliczymy odleglosci tych zrzutowanych punktow i to te odleglosci
      bedziemy porownywac z FogNode.VisibilityRange. To jest poprawna metoda.
      I w ten sposob np. mozemy zrobic mgle bardziej gesta w jednym kierunku
      a mniej w drugim. Fajne.

      Zupelnie nie wiem jak to zrobic w OpenGLu - jego GL_FOG_END (chyba)
      nie przechodzi takiej transformacji. Wiec w OpenGLu nie zrobie
      przy pomocy glFog takiej mgly (a przeciez samemu robic mgle nie bedzie
      mi sie chcialo, nie mowiac juz o tym ze zalezy mi na szybkosci a strace
      ja jesli bede implementowal rzeczy ktore juz sa w OpenGLu).
    }
    FFogDistanceScaling := FogAverageScaleTransform;
  end else
    FFogNode := nil;

  Include(Validities, fvFog);
 finally InitialState.Free end;
end;

function TVRMLScene.FogNode: TNodeFog;
begin
 if not (fvFog in Validities) then ValidateFog;
 result := FFogNode;
end;

function TVRMLScene.FogDistanceScaling: Single;
begin
 if not (fvFog in Validities) then ValidateFog;
 result := FFogDistanceScaling;
end;

{ triangles list ------------------------------------------------------------- }

procedure TVRMLScene.ValidateTrianglesList(OverTriangulate: boolean);
var
  ValidityValue: TVRMLSceneValidity;
begin
  if OverTriangulate then
    ValidityValue := fvTrianglesListOverTriangulate else
    ValidityValue := fvTrianglesListNotOverTriangulate;
  if not (ValidityValue in Validities) then
  begin
    FreeAndNil(FTrianglesList[OverTriangulate]);
    FTrianglesList[OverTriangulate] := CreateTrianglesList(OverTriangulate);
    Include(Validities, ValidityValue);
  end;
end;

type
  TTriangleAdder = class
    TriangleList: TDynTriangle3SingleArray;
    procedure AddTriangle(const Triangle: TTriangle3Single;
      State: TVRMLGraphTraverseState;
      GeometryNode: TVRMLGeometryNode;
      const MatNum, FaceCoordIndexBegin, FaceCoordIndexEnd: integer);
  end;

  procedure TTriangleAdder.AddTriangle(const Triangle: TTriangle3Single;
    State: TVRMLGraphTraverseState;
    GeometryNode: TVRMLGeometryNode;
    const MatNum, FaceCoordIndexBegin, FaceCoordIndexEnd: integer);
  begin
    if IsValidTriangle(Triangle) then
      TriangleList.AppendItem(Triangle);
  end;

function TVRMLScene.CreateTrianglesList(OverTriangulate: boolean):
  TDynTriangle3SingleArray;
var
  I: Integer;
  TriangleAdder: TTriangleAdder;
begin
  Result := TDynTriangle3SingleArray.Create;
  try
    Result.AllowedCapacityOverflow := TrianglesCount(false);
    try
      TriangleAdder := TTriangleAdder.Create;
      try
        TriangleAdder.TriangleList := Result;
        for I := 0 to ShapeStates.Count - 1 do
          ShapeStates[I].GeometryNode.Triangulate(
            ShapeStates[I].State, OverTriangulate,
            {$ifdef FPC_OBJFPC} @ {$endif} TriangleAdder.AddTriangle);
      finally FreeAndNil(TriangleAdder) end;
    finally Result.AllowedCapacityOverflow := 4 end;
  except Result.Free; raise end;
end;

function TVRMLScene.TrianglesList(OverTriangulate: boolean):
  TDynTriangle3SingleArray;
begin
  ValidateTrianglesList(OverTriangulate);
  Result := FTrianglesList[OverTriangulate];
end;

{ edges lists ------------------------------------------------------------- }

procedure TVRMLScene.CalculateIfNeededManifoldAndBorderEdges;

  { Sets FManifoldEdges and FBorderEdges. Assumes that FManifoldEdges and
    FBorderEdges are @nil on enter. }
  procedure CalculateManifoldAndBorderEdges;

    { If the counterpart of this edge (edge from neighbor) exists in
      EdgesSingle, then it adds this edge (along with it's counterpart)
      to FManifoldEdges.

      Otherwise, it just adds the edge to EdgesSingle. This can happen
      if it's the 1st time this edge occurs, or maybe the 3d one, 5th...
      all odd occurences, assuming that ordering of faces is consistent,
      so that counterpart edges are properly detected. }
    procedure AddEdgeCheckManifold(
      EdgesSingle: TDynManifoldEdgeArray;
      const TriangleIndex: Cardinal;
      const V0: TVector3Single;
      const V1: TVector3Single;
      const VertexIndex: Cardinal;
      Triangles: TDynTriangle3SingleArray);
    var
      I: Integer;
      EdgePtr: PManifoldEdge;
    begin
      if EdgesSingle.Count <> 0 then
      begin
        EdgePtr := EdgesSingle.Pointers[0];
        for I := 0 to EdgesSingle.Count - 1 do
        begin
          { It would also be possible to get EdgePtr^.V0/1 by code like

            TrianglePtr := @Triangles.Items[EdgePtr^.Triangles[0]];
            EdgeV0 := @TrianglePtr^[EdgePtr^.VertexIndex];
            EdgeV1 := @TrianglePtr^[(EdgePtr^.VertexIndex + 1) mod 3];

            But, see TManifoldEdge.V0/1 comments --- current version is
            a little faster.
          }

          { Triangles must be consistently ordered on a manifold,
            so the second time an edge is present, we know it must
            be in different order. So we compare V0 with EdgeV1
            (and V1 with EdgeV0), no need to compare V1 with EdgeV1. }
          if VectorsPerfectlyEqual(V0, EdgePtr^.V1) and
             VectorsPerfectlyEqual(V1, EdgePtr^.V0) then
          begin
            EdgePtr^.Triangles[1] := TriangleIndex;

            { Move edge to FManifoldEdges: it has 2 neighboring triangles now. }
            FManifoldEdges.AppendItem(EdgePtr^);

            { Remove this from EdgesSingle.
              Note that we delete from EdgesSingle fast, using assignment and
              deleting only from the end (normal Delete would want to shift
              EdgesSingle contents in memory, to preserve order of items;
              but we don't care about order). }
            EdgePtr^ := EdgesSingle.Items[EdgesSingle.Count - 1];
            EdgesSingle.DecLength;

            Exit;
          end;
          Inc(EdgePtr);
        end;
      end;

      { New edge: add new item to EdgesSingle }
      EdgesSingle.IncLength;
      EdgePtr := EdgesSingle.Pointers[EdgesSingle.High];
      EdgePtr^.VertexIndex := VertexIndex;
      EdgePtr^.Triangles[0] := TriangleIndex;
      EdgePtr^.V0 := V0;
      EdgePtr^.V1 := V1;
    end;

  var
    I: Integer;
    Triangles: TDynTriangle3SingleArray;
    TrianglePtr: PTriangle3Single;
    EdgesSingle: TDynManifoldEdgeArray;
  begin
    Assert(FManifoldEdges = nil);
    Assert(FBorderEdges = nil);

    { It's important here that TrianglesList guarentees that only valid
      triangles are included. Otherwise degenerate triangles could make
      shadow volumes rendering result bad. }
    Triangles := TrianglesList(false);

    FManifoldEdges := TDynManifoldEdgeArray.Create;
    { There is a precise relation between number of edges and number of faces
      on a closed manifold: E = T * 3 / 2. }
    FManifoldEdges.AllowedCapacityOverflow := Triangles.Count * 3 div 2;

    { EdgesSingle are edges that have no neighbor,
      i.e. have only one adjacent triangle. At the end, what's left here
      will be simply copied to BorderEdges. }
    EdgesSingle := TDynManifoldEdgeArray.Create;
    try
      EdgesSingle.AllowedCapacityOverflow := Triangles.Count * 3 div 2;

      TrianglePtr := Triangles.Pointers[0];
      for I := 0 to Triangles.Count - 1 do
      begin
        { TrianglePtr points to Triangles[I] now }
        AddEdgeCheckManifold(EdgesSingle, I, TrianglePtr^[0], TrianglePtr^[1], 0, Triangles);
        AddEdgeCheckManifold(EdgesSingle, I, TrianglePtr^[1], TrianglePtr^[2], 1, Triangles);
        AddEdgeCheckManifold(EdgesSingle, I, TrianglePtr^[2], TrianglePtr^[0], 2, Triangles);
        Inc(TrianglePtr);
      end;

      FBorderEdges := TDynBorderEdgeArray.Create;

      if EdgesSingle.Count <> 0 then
      begin
        { scene not a perfect manifold: less than 2 faces for some edges
          (the case with more than 2 is already eliminated above).
          So we copy EdgesSingle to BorderEdges. }
        FBorderEdges.Count := EdgesSingle.Count;
        for I := 0 to EdgesSingle.Count - 1 do
        begin
          FBorderEdges.Items[I].VertexIndex := EdgesSingle.Items[I].VertexIndex;
          FBorderEdges.Items[I].TriangleIndex := EdgesSingle.Items[I].Triangles[0];
        end;
      end;
    finally FreeAndNil(EdgesSingle); end;
  end;

begin
  if not (fvManifoldAndBorderEdges in Validities) then
  begin
    FOwnsManifoldAndBorderEdges := true;
    CalculateManifoldAndBorderEdges;
    Include(Validities, fvManifoldAndBorderEdges);
  end;
end;

function TVRMLScene.ManifoldEdges: TDynManifoldEdgeArray;
begin
  CalculateIfNeededManifoldAndBorderEdges;
  Result := FManifoldEdges;
end;

function TVRMLScene.BorderEdges: TDynBorderEdgeArray;
begin
  CalculateIfNeededManifoldAndBorderEdges;
  Result := FBorderEdges;
end;

procedure TVRMLScene.ShareManifoldAndBorderEdges(
  ManifoldShared: TDynManifoldEdgeArray;
  BorderShared: TDynBorderEdgeArray);
begin
  Assert(
    (ManifoldShared = FManifoldEdges) =
    (BorderShared = FBorderEdges),
    'For ShareManifoldAndBorderEdges, either both ManifoldShared and ' +
    'BorderShared should be the same as already owned, or both should ' +
    'be different. If you have a good reason to break this, report, ' +
    'implementation of ShareManifoldAndBorderEdges may be improved ' +
    'if it''s needed');

  if (fvManifoldAndBorderEdges in Validities) and
    (ManifoldShared = FManifoldEdges) then
    { No need to do anything in this case.

      If ManifoldShared = FManifoldEdges = nil, then we may leave
      FOwnsManifoldAndBorderEdges = true
      while it could be = false (if we let this procedure continue),
      but this doesn't matter (since FOwnsManifoldAndBorderEdges doesn't matter
      when FManifoldEdges = nil).

      If ManifoldShared <> nil and old FOwnsManifoldAndBorderEdges is false
      then this doesn't change anything.

      Finally, the important case: If ManifoldShared <> nil and old
      FOwnsManifoldAndBorderEdges is true. Then it would be very very bad
      to continue this method, as we would free FManifoldEdges pointer
      and right away set FManifoldEdges to the same pointer (that would
      be invalid now). }
    Exit;

  if FOwnsManifoldAndBorderEdges then
  begin
    FreeAndNil(FManifoldEdges);
    FreeAndNil(FBorderEdges);
  end;

  FManifoldEdges := ManifoldShared;
  FBorderEdges := BorderShared;
  FOwnsManifoldAndBorderEdges := false;
  Include(Validities, fvManifoldAndBorderEdges);
end;

{ freeing resources ---------------------------------------------------------- }

procedure TVRMLScene.FreeResources_UnloadTextureData(Node: TVRMLNode);
begin
  (Node as TVRMLTextureNode).IsTextureLoaded := false;
end;

procedure TVRMLScene.FreeResources_UnloadBackgroundImage(Node: TVRMLNode);
begin
  (Node as TNodeBackground).BgImagesLoaded := false;
end;

procedure TVRMLScene.FreeResources(Resources: TVRMLSceneFreeResources);
begin
  if (frRootNode in Resources) and OwnsRootNode then
  begin
    RootNode.Free;
    RootNode := nil;
  end;

  if (frTextureDataInNodes in Resources) and (RootNode <> nil) then
    RootNode.EnumerateNodes(TVRMLTextureNode,
      @FreeResources_UnloadTextureData, false);

  if (frBackgroundImageInNodes in Resources) and (RootNode <> nil) then
    RootNode.EnumerateNodes(TNodeBackground,
      @FreeResources_UnloadBackgroundImage, false);

  if frTrianglesListNotOverTriangulate in Resources then
  begin
    Exclude(Validities, fvTrianglesListNotOverTriangulate);
    FreeAndNil(FTrianglesList[false]);
  end;

  if frTrianglesListOverTriangulate in Resources then
  begin
    Exclude(Validities, fvTrianglesListOverTriangulate);
    FreeAndNil(FTrianglesList[true]);
  end;

  if frManifoldAndBorderEdges in Resources then
  begin
    Exclude(Validities, fvManifoldAndBorderEdges);
    if FOwnsManifoldAndBorderEdges then
    begin
      FreeAndNil(FManifoldEdges);
      FreeAndNil(FBorderEdges);
    end else
    begin
      FManifoldEdges := nil;
      FBorderEdges := nil;
    end;
  end;
end;

{ events --------------------------------------------------------------------- }

{ We're using AddIfNotExists, not simple Add, in Collect_ routines
  below:

  - for time-dependent nodes (TimeSensor, MovieTexture etc.),
    duplicates would cause time to be then incremented many times
    during single SetWorldTime, so their local time would grow too fast.

  - for other sensors, events would be passed twice.
}

procedure TVRMLScene.Collect_KeySensor(Node: TVRMLNode);
begin
  Assert(Node is TNodeKeySensor);
  KeySensorNodes.AddIfNotExists(Node);
end;

procedure TVRMLScene.Collect_TimeSensor(Node: TVRMLNode);
begin
  Assert(Node is TNodeTimeSensor);
  TimeSensorNodes.AddIfNotExists(Node);
end;

procedure TVRMLScene.Collect_MovieTexture(Node: TVRMLNode);
begin
  Assert(Node is TNodeMovieTexture);
  MovieTextureNodes.AddIfNotExists(Node);
end;

procedure TVRMLScene.EventChanged(
  Event: TVRMLEvent; Value: TVRMLField; const Time: TKamTime);
begin
  if Event.ParentNode <> nil then
    ChangedFields(Event.ParentNode as TVRMLNode) else
    { Although EventChanged indicates that only some field's value changed,
      so ChangedFields is most optimal, but without Event.ParentNode
      we don't know which node actually changed... Calling ChangedAll
      is the only fallback here. This shouldn't really happen with current
      code (all normal fields have ParentNode set, and so their ExposedEvents
      also have ParentNode set). }
    ChangedAll;
end;

procedure TVRMLScene.Collect_ChangedFields(Node: TVRMLNode);
var
  I: Integer;
begin
  for I := 0 to Node.Fields.Count - 1 do
    if Node.Fields[I].Exposed then
    begin
      Node.Fields[I].ExposedEvents[false].OnReceive.AddIfNotExists(@EventChanged);

      { TODO: this is not nice, as we never remove EventChanged from
        events OnReceive list. We should remove then when ProcessEvents
        becomes @false (including on destroy of TVRMLScene).
        Also when RootNode changes, we shoudn't be tied to old events...

        AddIfNotExists at least prevents us from registering EventChanged
        multiple times (when ChangedAll, and so CollectNodesForEvents,
        is called multiple times).

        This will be a problem if a VRML scene will be heavily processed
        by our own routines (including destroying of RootNode or
        other nodes), and at the same time ProcessEvents = @true.
        This will not work nicely, document?

        The same problem occurs with Node.Event[I].OnReceive.AddIfNotExists
        lower. }
    end;

  if Node is TNodeComposedShader then
  begin
    { For ComposedShader nodes, we have to watch for changes to
      inputOnly events too, to call DoPostRedisplay (in ChangedFields)
      for them. }
    for I := 0 to Node.Events.Count - 1 do
      if Node.Events[I].InEvent then
        Node.Events[I].OnReceive.AddIfNotExists(@EventChanged);
  end;
end;

procedure TVRMLScene.CollectNodesForEvents;
begin
  KeySensorNodes.Clear;
  RootNode.EnumerateNodes(TNodeKeySensor, @Collect_KeySensor, false);

  TimeSensorNodes.Clear;
  RootNode.EnumerateNodes(TNodeTimeSensor, @Collect_TimeSensor, false);

  MovieTextureNodes.Clear;
  RootNode.EnumerateNodes(TNodeMovieTexture, @Collect_MovieTexture, false);

  RootNode.EnumerateNodes(TVRMLNode, @Collect_ChangedFields, false);
end;

procedure TVRMLScene.SetProcessEvents(const Value: boolean);
begin
  if FProcessEvents <> Value then
  begin
    if Value then
    begin
      KeySensorNodes := TVRMLNodesList.Create;
      TimeSensorNodes := TVRMLNodesList.Create;
      MovieTextureNodes := TVRMLNodesList.Create;
      CollectNodesForEvents;
    end else
    begin
      FreeAndNil(KeySensorNodes);
      FreeAndNil(TimeSensorNodes);
      FreeAndNil(MovieTextureNodes);
    end;
    FProcessEvents := Value;
  end;
end;

{ Convert TKey to VRML "action" key code.
  As defined by X3D KeySensor node specification. }
function KeyToActionKey(Key: TKey; out ActionKey: Integer): boolean;
begin
  Result := true;
  case Key of
    K_F1 .. K_F12 : ActionKey := Key - K_F1 + 1;
    K_Home     : ActionKey := 13;
    K_End      : ActionKey := 14;
    K_PageUp   : ActionKey := 15;
    K_PageDown : ActionKey := 16;
    K_Up       : ActionKey := 17;
    K_Down     : ActionKey := 18;
    K_Left     : ActionKey := 19;
    K_Right    : ActionKey := 20;
    else Result := false;
  end;
end;

procedure TVRMLScene.KeyDown(Key: TKey; C: char; KeysDown: PKeysBooleans);
var
  I: Integer;
  KeySensor: TNodeKeySensor;
  ActionKey: Integer;
begin
  if ProcessEvents then
  begin
    for I := 0 to KeySensorNodes.Count - 1 do
    begin
      KeySensor := KeySensorNodes.Items[I] as TNodeKeySensor;
      if KeySensor.FdEnabled.Value then
      begin
        KeySensor.EventIsActive.Send(true, WorldTime);
        if KeyToActionKey(Key, ActionKey) then
          KeySensor.EventActionKeyPress.Send(ActionKey, WorldTime);
        KeySensor.EventKeyPress.Send(C, WorldTime);
        case Key of
          K_Alt: KeySensor.EventAltKey.Send(true, WorldTime);
          K_Ctrl: KeySensor.EventControlKey.Send(true, WorldTime);
          K_Shift: KeySensor.EventShiftKey.Send(true, WorldTime);
        end;
      end;
    end;
  end;
end;

procedure TVRMLScene.KeyUp(Key: TKey);
var
  I: Integer;
  KeySensor: TNodeKeySensor;
  ActionKey: Integer;
begin
  if ProcessEvents then
  begin
    for I := 0 to KeySensorNodes.Count - 1 do
    begin
      KeySensor := KeySensorNodes.Items[I] as TNodeKeySensor;
      if KeySensor.FdEnabled.Value then
      begin
        KeySensor.EventIsActive.Send(false, WorldTime);
        if KeyToActionKey(Key, ActionKey) then
          KeySensor.EventActionKeyRelease.Send(ActionKey, WorldTime);
        { TODO: KeySensor.EventKeyRelease.Send(C, WorldTime) would be nice here }
        case Key of
          K_Alt: KeySensor.EventAltKey.Send(false, WorldTime);
          K_Ctrl: KeySensor.EventControlKey.Send(false, WorldTime);
          K_Shift: KeySensor.EventShiftKey.Send(false, WorldTime);
        end;
      end;
    end;
  end;
end;

{ WorldTime stuff ------------------------------------------------------------ }

procedure TVRMLScene.InternalSetWorldTime(
  const NewValue, TimeIncrease: TKamTime);
var
  SomethingChanged: boolean;
  I: Integer;
begin
  if ProcessEvents then
  begin
    SomethingChanged := false;

    for I := 0 to MovieTextureNodes.Count - 1 do
      (MovieTextureNodes.Items[I] as TNodeMovieTexture).
        TimeDependentNodeHandler.SetWorldTime(
          WorldTime, NewValue, TimeIncrease, SomethingChanged);

    { If SomethingChanged on MovieTexture nodes, then we have to redisplay.
      Note that this is not needed for other time-dependent nodes
      (like TimeSensor), as they are not visible (and so can influence
      other nodes only by events, and this will change EventChanged
      to catch it). }
    if SomethingChanged then
      DoPostRedisplay;

    for I := 0 to TimeSensorNodes.Count - 1 do
      (TimeSensorNodes.Items[I] as TNodeTimeSensor).
        TimeDependentNodeHandler.SetWorldTime(
          WorldTime, NewValue, TimeIncrease, SomethingChanged);
  end;

  FWorldTime := NewValue;
end;

procedure TVRMLScene.SetWorldTime(const NewValue: TKamTime);
var
  TimeIncrease: TKamTime;
begin
  TimeIncrease := NewValue - FWorldTime;
  if TimeIncrease > 0 then
    InternalSetWorldTime(NewValue, TimeIncrease);
end;

procedure TVRMLScene.IncreaseWorldTime(const TimeIncrease: TKamTime);
begin
  if TimeIncrease > 0 then
    InternalSetWorldTime(FWorldTime + TimeIncrease, TimeIncrease);
end;

procedure TVRMLScene.ResetRoutesLastEventTime(Node: TVRMLNode);
var
  I: Integer;
begin
  for I := 0 to Node.Routes.Count - 1 do
    Node.Routes[I].ResetLastEventTime;
end;

procedure TVRMLScene.ResetWorldTime(const NewValue: TKamTime);
begin
  InternalSetWorldTime(NewValue, 0);
  if RootNode <> nil then
    RootNode.EnumerateNodes(@ResetRoutesLastEventTime, false);
end;

initialization
  TraverseState_CreateNodes(StateDefaultNodes);
finalization
  TraverseState_FreeAndNilNodes(StateDefaultNodes);
end.
