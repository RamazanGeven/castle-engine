{
  Copyright 2004-2005 Michalis Kamburelis.

  This file is part of "Kambi VRML game engine".

  "Kambi VRML game engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Kambi VRML game engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
}

unit TestVRMLGLScene;

interface

uses
  Classes, SysUtils, fpcunit, testutils, testregistry;

type
  TTestVRMLGLScene = class(TTestCase)
  published
    procedure TestVRMLGLScene;
  end;

implementation

uses VRMLNodes, VRMLScene, VRMLGLScene, Boxes3d, VectorMath;

procedure TTestVRMLGLScene.TestVRMLGLScene;

  procedure EmptySceneAsserts(EmptyScene: TVRMLGLScene);
  var
    CamKind: TVRMLCameraKind;
    CamPos, CamDir, CamUp, GravityUp: TVector3Single;
  begin
   Assert(EmptyScene.VerticesCount(false) = 0);
   Assert(EmptyScene.VerticesCount(true) = 0);
   Assert(EmptyScene.TrianglesCount(false) = 0);
   Assert(EmptyScene.TrianglesCount(true) = 0);

   Assert(IsEmptyBox3d(EmptyScene.BoundingBox));

   Assert(EmptyScene.ShapesActiveCount = 0);

   Assert(EmptyScene.GetViewpoint(CamKind, CamPos, CamDir, CamUp, GravityUp) = nil);

   Assert(EmptyScene.FogNode = nil);

   Assert(EmptyScene.Background = nil);
  end;

var EmptyScene: TVRMLGLScene;
begin
 EmptyScene := TVRMLGLScene.Create(nil, true, roSceneAsAWhole);
 try
  EmptySceneAsserts(EmptyScene);
  EmptyScene.ChangedAll;
  EmptySceneAsserts(EmptyScene);
 finally FreeAndNil(EmptyScene) end;

 EmptyScene := TVRMLGLScene.Create(TNodeGroup_1.Create('', ''), true,
   roSceneAsAWhole);
 try
  EmptySceneAsserts(EmptyScene);
  EmptyScene.ChangedAll;
  EmptySceneAsserts(EmptyScene);
 finally FreeAndNil(EmptyScene) end;
end;

initialization
 RegisterTest(TTestVRMLGLScene);
end.
